import AppKit
import Combine

/// Duración de una sesión manual. `minutes == nil` significa indefinida.
struct GhostDuration: Hashable, Identifiable {
    let minutes: Int?

    var id: Int { minutes ?? -1 }

    static let indefinite = GhostDuration(minutes: nil)
    static let presets: [GhostDuration] = [15, 30, 60, 120, 240].map { GhostDuration(minutes: $0) } + [.indefinite]

    var shortLabel: String {
        guard let minutes else { return "∞" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// Cerebro de Ghost: combina sesión manual, temporizador, triggers y protección de batería
/// en una única decisión ("¿debe el sistema mantenerse despierto?") y orquesta el Modo Ghost.
@MainActor
final class GhostController: ObservableObject {
    static let shared = GhostController()

    // Dependencias (propiedades calculadas para evitar inicializadores aislados en propiedades).
    var power: GhostPowerManager { .shared }
    var settings: GhostSettings { .shared }
    var curtain: BlackCurtainManager { .shared }
    private var hotkeys: GhostHotkeyManager { .shared }
    private let sampler = SystemLoadSampler()

    // Estado publicado para la UI.
    @Published private(set) var isAwake = false
    @Published private(set) var manualAwake = false
    @Published private(set) var selectedDuration: GhostDuration?
    @Published private(set) var sessionEndsAt: Date?
    @Published private(set) var ghostModeActive = false
    @Published private(set) var isDisplayAsleep = false
    @Published private(set) var curtainVisible = false
    @Published private(set) var triggerReasons: [String] = []
    @Published private(set) var cpuUsage: Double?
    @Published private(set) var networkKBps: Double?
    @Published private(set) var battery = BatteryStatus.unknown
    @Published private(set) var batteryLockout = false
    @Published private(set) var hotkeyRegistered = false
    @Published var notice: String?

    /// La UI lo usa para cerrar el popover antes de apagar la pantalla.
    var onRequestClosePopover: (@MainActor () -> Void)?

    static let monitorInterval: TimeInterval = 5
    static let triggerCooldown: TimeInterval = 60
    /// Tope de una sesión temporizada (30 días). Más allá, usar "sin límite".
    static let maxSessionMinutes = 30 * 24 * 60

    private var sessionTimer: Timer?
    private var monitorTimer: Timer?
    private var pendingDisplaySleep: Task<Void, Never>?
    private var lastCPUHighAt: Date?
    private var lastNetworkHighAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusWriteScheduled = false
    private var lastWrittenStatus = ""
    private var started = false

    private init() {}

    // MARK: - Ciclo de vida

    func start() {
        guard !started else { return }
        started = true

        hotkeys.onPressed = { [weak self] in
            self?.handleHotkey()
        }
        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.registerHotkey(shortcut)
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.settingsDidChange() }
            }
            .store(in: &cancellables)

        power.$isDisplayAsleep
            .removeDuplicates()
            .sink { [weak self] asleep in
                self?.displaySleepChanged(asleep)
            }
            .store(in: &cancellables)

        curtain.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.curtainVisibilityChanged(visible)
            }
            .store(in: &cancellables)

        curtain.onDismissRequested = { [weak self] in
            self?.exitGhostMode()
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateTriggers()
                    self?.reconcile()
                }
            }
            workspaceObservers.append(observer)
        }

        let timer = Timer(timeInterval: Self.monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer

        tick()
    }

    func shutdown() {
        pendingDisplaySleep?.cancel()
        pendingDisplaySleep = nil
        sessionTimer?.invalidate()
        monitorTimer?.invalidate()
        curtain.hide()
        hotkeys.unregister()
        power.releaseAll()
        try? FileManager.default.removeItem(at: Self.statusFileURL)
    }

    // MARK: - Sesión manual y temporizador

    func enable(_ duration: GhostDuration) {
        refreshBattery()
        if batteryLockout {
            notice = "Batería por debajo de \(settings.batteryThreshold)% sin cargador: Ghost está en pausa para protegerla."
            reconcile()
            return
        }

        manualAwake = true
        selectedDuration = duration
        sessionTimer?.invalidate()
        sessionTimer = nil

        if let minutes = duration.minutes {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sessionEndsAt = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.sessionExpired() }
            }
            RunLoop.main.add(timer, forMode: .common)
            sessionTimer = timer
        } else {
            sessionEndsAt = nil
        }

        notice = nil
        reconcile()
    }

    func disable() {
        manualAwake = false
        selectedDuration = nil
        sessionEndsAt = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        reconcile()
    }

    func toggleAwake() {
        manualAwake ? disable() : enable(.indefinite)
    }

    private func sessionExpired() {
        guard manualAwake, let end = sessionEndsAt, Date() >= end.addingTimeInterval(-1) else { return }
        // Sin sesión despierta no hay Modo Ghost: se sale de él aunque la pantalla siga apagada
        // (no se enciende; solo deja de reportarse "Modo Ghost activo").
        pendingDisplaySleep?.cancel()
        pendingDisplaySleep = nil
        if curtain.isVisible { curtain.hide() }
        ghostModeActive = false
        disable()
        notice = "Temporizador terminado: el Mac vuelve a su reposo normal."
    }

    // MARK: - Modo Ghost

    /// Atajo global: alterna entre apagar y encender la pantalla.
    func handleHotkey() {
        // Si la pantalla estaba apagada, la propia pulsación ya la despertó a nivel HID
        // un instante antes de que llegue este evento; por eso se mira el despertar reciente.
        let recentlyWoke = Date().timeIntervalSince(power.lastDisplayWakeAt) < 2
        if curtain.isVisible || power.isDisplayAsleep || pendingDisplaySleep != nil || recentlyWoke {
            exitGhostMode()
        } else {
            enterGhostMode()
        }
    }

    func toggleGhostMode() {
        ghostModeActive ? exitGhostMode() : enterGhostMode()
    }

    /// Mantiene el sistema despierto y apaga la pantalla (o muestra la cortina negra).
    func enterGhostMode(forceCurtain: Bool = false) {
        if !manualAwake {
            enable(.indefinite)
        }
        if batteryLockout {
            notice = "Modo Ghost no disponible: batería baja sin cargador."
            return
        }

        ghostModeActive = true
        onRequestClosePopover?()

        if forceCurtain || settings.useBlackCurtain {
            curtain.show(hint: "Modo Ghost · \(settings.hotkey.display), Esc o doble clic para salir")
        } else {
            scheduleDisplaySleep()
        }
        scheduleStatusWrite()
    }

    func exitGhostMode() {
        pendingDisplaySleep?.cancel()
        pendingDisplaySleep = nil
        ghostModeActive = false
        curtain.hide()
        power.wakeDisplay()
        scheduleStatusWrite()
    }

    /// Espera a que se suelten las teclas/botones: el key-up del propio atajo o del clic
    /// volvería a encender la pantalla justo después de apagarla.
    private func scheduleDisplaySleep() {
        pendingDisplaySleep?.cancel()
        let keyCode = CGKeyCode(settings.hotkey.keyCode)
        pendingDisplaySleep = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, GhostController.inputStillHeld(keyCode: keyCode) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingDisplaySleep = nil
            guard self.ghostModeActive else { return }
            self.power.sleepDisplayNow()
        }
    }

    private static func inputStillHeld(keyCode: CGKeyCode) -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return true }
        if CGEventSource.keyState(.combinedSessionState, key: keyCode) { return true }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { return true }
        return false
    }

    private func displaySleepChanged(_ asleep: Bool) {
        isDisplayAsleep = asleep
        // Si el usuario despierta la pantalla con el ratón/teclado, el Modo Ghost termina.
        if !asleep, ghostModeActive, !curtain.isVisible, pendingDisplaySleep == nil {
            ghostModeActive = false
        }
        scheduleStatusWrite()
    }

    private func curtainVisibilityChanged(_ visible: Bool) {
        curtainVisible = visible
        if !visible, ghostModeActive, !isDisplayAsleep, pendingDisplaySleep == nil {
            ghostModeActive = false
        }
        scheduleStatusWrite()
    }

    // MARK: - Atajo

    private func registerHotkey(_ shortcut: GhostShortcut) {
        hotkeyRegistered = hotkeys.register(shortcut)
    }

    /// Vuelve a registrar el atajo guardado (p. ej. al terminar de grabar uno nuevo) y
    /// mantiene `hotkeyRegistered` coherente con el registro real.
    func reregisterHotkey() {
        registerHotkey(settings.hotkey)
    }

    // MARK: - Monitorización, triggers y batería

    private func tick() {
        let now = Date()
        if let cpu = sampler.sampleCPUPercent() {
            cpuUsage = cpu
            if settings.cpuTriggerEnabled, cpu >= settings.cpuThreshold { lastCPUHighAt = now }
        }
        if let rate = sampler.sampleNetworkKBps() {
            networkKBps = rate
            if settings.networkTriggerEnabled, rate >= settings.networkThresholdKBps { lastNetworkHighAt = now }
        }
        refreshBattery()
        if let end = sessionEndsAt, now >= end {
            sessionExpired()
        }
        evaluateTriggers()
        reconcile()
    }

    private func settingsDidChange() {
        if !settings.cpuTriggerEnabled { lastCPUHighAt = nil }
        if !settings.networkTriggerEnabled { lastNetworkHighAt = nil }
        refreshBattery()
        evaluateTriggers()
        reconcile()
    }

    private func refreshBattery() {
        let status = PowerSourceReader.read()
        if status != battery { battery = status }

        let isLow = settings.batteryProtectionEnabled
            && status.hasBattery
            && !status.isOnAC
            && (status.percent ?? 100) <= settings.batteryThreshold

        if isLow, !batteryLockout {
            batteryLockout = true
            if curtain.isVisible { curtain.hide() }
            ghostModeActive = false
            if manualAwake { disable() }
            notice = "Batería al \(status.percent ?? 0)% sin cargador: Ghost se desactivó para protegerla."
        } else if !isLow, batteryLockout {
            batteryLockout = false
            notice = nil
        }
    }

    private func evaluateTriggers() {
        var reasons: [String] = []
        let now = Date()

        if settings.appTriggerEnabled {
            let watched = Set(settings.watchedApps.map { $0.lowercased() })
            if !watched.isEmpty {
                for app in NSWorkspace.shared.runningApplications {
                    let identifiers = [app.bundleIdentifier?.lowercased(), app.localizedName?.lowercased()].compactMap { $0 }
                    guard identifiers.contains(where: { watched.contains($0) }) else { continue }
                    let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                    if !reasons.contains(name) { reasons.append(name) }
                }
            }
        }

        if settings.cpuTriggerEnabled, let last = lastCPUHighAt, now.timeIntervalSince(last) < Self.triggerCooldown {
            reasons.append("CPU")
        }
        if settings.networkTriggerEnabled, let last = lastNetworkHighAt, now.timeIntervalSince(last) < Self.triggerCooldown {
            reasons.append("Red")
        }

        if reasons != triggerReasons { triggerReasons = reasons }
    }

    /// Única fuente de verdad sobre la aserción de energía.
    private func reconcile() {
        let shouldStayAwake = !batteryLockout && (manualAwake || !triggerReasons.isEmpty)

        let reason: String
        if manualAwake {
            reason = sessionEndsAt == nil ? "Ghost: modo manual" : "Ghost: temporizador"
        } else {
            reason = "Ghost: trigger (\(triggerReasons.joined(separator: ", ")))"
        }

        if !power.setPreventSleep(shouldStayAwake, reason: reason), shouldStayAwake {
            notice = "macOS rechazó la aserción de energía. Revisa Console.app (proceso Ghost)."
        }
        let awake = power.isPreventingSleep
        if awake != isAwake { isAwake = awake }
        scheduleStatusWrite()
    }

    // MARK: - Texto de estado

    var statusLine: String {
        if batteryLockout { return "En pausa · batería baja" }
        if ghostModeActive { return curtainVisible ? "Modo Ghost · cortina negra" : "Modo Ghost · pantalla apagada" }
        if manualAwake { return sessionEndsAt == nil ? "Despierto · sin límite" : "Despierto · temporizador" }
        if !triggerReasons.isEmpty { return "Despierto por " + triggerReasons.joined(separator: ", ") }
        return "Inactivo · el Mac duerme con normalidad"
    }

    // MARK: - URL scheme (ghost://…) — también lo usa el CLI

    static func command(from url: URL) -> String {
        if let host = url.host, !host.isEmpty { return host.lowercased() }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Procesa comandos de energía. Devuelve false si el comando no es suyo.
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "ghost" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch Self.command(from: url) {
        case "on", "enable", "start":
            if let raw = value("minutes") ?? value("hours") {
                // Cualquier app o web puede abrir ghost://: valida antes de convertir a Int
                // (un valor enorme o "inf" desbordaría y cerraría la app).
                let isHours = value("minutes") == nil
                guard let number = Double(raw), number.isFinite, number > 0 else {
                    NSLog("Ghost: duración no válida en %@", url.absoluteString)
                    return true
                }
                let minutes = min(isHours ? number * 60 : number, Double(Self.maxSessionMinutes))
                enable(GhostDuration(minutes: max(1, Int(minutes))))
            } else {
                enable(.indefinite)
            }
        case "off", "disable", "stop":
            if ghostModeActive { exitGhostMode() }
            disable()
        case "toggle":
            toggleAwake()
        case "sleep", "ghost", "dark", "screen-off":
            enterGhostMode()
        case "curtain":
            enterGhostMode(forceCurtain: true)
        case "wake", "screen-on":
            exitGhostMode()
        case "toggle-ghost":
            handleHotkey()
        case "status", "refresh":
            tick()
        default:
            return false
        }
        return true
    }

    // MARK: - Archivo de estado para `ghost status`

    static var statusFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ghost", isDirectory: true).appendingPathComponent("status")
    }

    private func scheduleStatusWrite() {
        guard !statusWriteScheduled else { return }
        statusWriteScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.statusWriteScheduled = false
            self.writeStatusNow()
        }
    }

    private func writeStatusNow() {
        let lines = [
            "running=1",
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "awake=\(isAwake ? 1 : 0)",
            "manual=\(manualAwake ? 1 : 0)",
            "ghost_mode=\(ghostModeActive ? 1 : 0)",
            "display_asleep=\(power.isDisplayAsleep ? 1 : 0)",
            "curtain=\(curtain.isVisible ? 1 : 0)",
            "ends_at=\(Int(sessionEndsAt?.timeIntervalSince1970 ?? 0))",
            "triggers=\(triggerReasons.joined(separator: ","))",
            "has_battery=\(battery.hasBattery ? 1 : 0)",
            "battery=\(battery.percent.map(String.init) ?? "-")",
            "on_ac=\(battery.isOnAC ? 1 : 0)",
            "battery_lockout=\(batteryLockout ? 1 : 0)",
            "hotkey=\(settings.hotkey.display)",
            "hotkey_ok=\(hotkeyRegistered ? 1 : 0)"
        ]
        let content = lines.joined(separator: "\n") + "\n"
        guard content != lastWrittenStatus else { return }

        let url = Self.statusFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastWrittenStatus = content
        } catch {
            NSLog("Ghost: no se pudo escribir el estado: %@", error.localizedDescription)
        }
    }
}
