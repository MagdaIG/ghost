import AppKit
import Combine
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Cómo logra Ghost "sistema despierto + pantalla apagada"
//
// macOS decide dormir en función de *aserciones* de energía (pmset -g assertions):
//
//  • PreventUserIdleSystemSleep  → el sistema (CPU, red, discos) no entra en reposo por
//    inactividad. Es la aserción principal de Ghost. Funciona con batería y con corriente.
//  • PreventUserIdleDisplaySleep → impide que la pantalla se apague. Ghost SOLO la crea en
//    Modo Sonámbulo (opción explícita del usuario) y la suelta mientras está en Modo Ghost;
//    el resto del tiempo la pantalla respeta el "apagar pantalla tras X minutos" del sistema.
//
// Para el Modo Ghost se apaga la pantalla al instante con `pmset displaysleepnow`
// (fallback: IORequestIdle en IODisplayWrangler). Para despertarla se declara actividad
// de usuario con IOPMAssertionDeclareUserActivity, que enciende el panel sin inyectar
// eventos de teclado/ratón en ninguna app.
//
// El kernel libera automáticamente todas las aserciones si Ghost se cierra o falla,
// así que nunca deja el Mac "atascado" sin dormir.

// MARK: - Batería

struct BatteryStatus: Equatable {
    var hasBattery: Bool
    var isOnAC: Bool
    var percent: Int?

    static let unknown = BatteryStatus(hasBattery: false, isOnAC: true, percent: nil)

    var summary: String {
        guard hasBattery, let percent else { return "Corriente (sin batería)" }
        return "\(percent)% · " + (isOnAC ? "con cargador" : "con batería")
    }
}

enum PowerSourceReader {
    static func read() -> BatteryStatus {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }

        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let isOnAC = providing != kIOPSBatteryPowerValue

        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            return BatteryStatus(hasBattery: false, isOnAC: isOnAC, percent: nil)
        }

        for source in list as NSArray {
            guard
                let rawDescription = IOPSGetPowerSourceDescription(snapshot, source as AnyObject)?.takeUnretainedValue(),
                let description = (rawDescription as NSDictionary) as? [String: Any],
                (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            if let present = description[kIOPSIsPresentKey] as? Bool, !present { continue }

            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            return BatteryStatus(hasBattery: true, isOnAC: isOnAC, percent: percent)
        }
        return BatteryStatus(hasBattery: false, isOnAC: isOnAC, percent: nil)
    }
}

// MARK: - CPU y red

/// Muestrea uso de CPU (host_statistics) y tráfico de red (getifaddrs) por diferencia
/// entre dos lecturas consecutivas. La primera llamada de cada métrica devuelve nil.
final class SystemLoadSampler {
    private let host = mach_host_self()
    private var lastCPUTicks: [UInt32]?
    private var lastNetworkCounters: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastNetworkSampleAt: Date?

    /// Porcentaje de CPU ocupada (0–100) de todo el sistema desde la muestra anterior.
    func sampleCPUPercent() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { reboundPointer in
                host_statistics(host, HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Orden: CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE
        let ticks = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3]
        defer { lastCPUTicks = ticks }
        guard let previous = lastCPUTicks else { return nil }

        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let busy = delta[0] + delta[1] + delta[3]
        let total = busy + delta[2]
        guard total > 0 else { return nil }
        return min(100, max(0, busy / total * 100))
    }

    /// Tráfico total (entrada + salida) en KB/s, excluyendo loopback y túneles virtuales.
    func sampleNetworkKBps() -> Double? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            cursor = interface.ifa_next

            guard
                let address = interface.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                let data = interface.ifa_data
            else { continue }

            let name = String(cString: interface.ifa_name)
            let ignoredPrefixes = ["lo", "utun", "awdl", "llw", "gif", "stf", "anpi", "ap"]
            if ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }

        let now = Date()
        defer {
            lastNetworkCounters = current
            lastNetworkSampleAt = now
        }
        guard let lastSample = lastNetworkSampleAt else { return nil }
        let elapsed = now.timeIntervalSince(lastSample)
        guard elapsed > 0.5 else { return nil }

        var bytes: UInt64 = 0
        for (name, counters) in current {
            guard let previous = lastNetworkCounters[name] else { continue }
            // Los contadores de if_data son de 32 bits: la resta con desbordamiento gestiona el wrap.
            bytes += UInt64(counters.rx &- previous.rx) + UInt64(counters.tx &- previous.tx)
        }
        return Double(bytes) / 1024 / elapsed
    }
}

// MARK: - Power manager

@MainActor
final class GhostPowerManager: NSObject, ObservableObject {
    static let shared = GhostPowerManager()

    /// true mientras Ghost mantiene la aserción PreventUserIdleSystemSleep.
    @Published private(set) var isPreventingSleep = false
    /// true mientras Ghost mantiene PreventUserIdleDisplaySleep (solo en Modo Sonámbulo).
    @Published private(set) var isPreventingDisplaySleep = false
    /// Estado real de las pantallas según NSWorkspace (screensDidSleep / screensDidWake).
    @Published private(set) var isDisplayAsleep = false
    /// Momento del último despertar de pantalla (sirve para resolver la carrera del atajo).
    private(set) var lastDisplayWakeAt = Date.distantPast

    private var sleepAssertionID: IOPMAssertionID = 0
    private var sleepAssertionReason = ""
    private var displayAssertionID: IOPMAssertionID = 0
    private var activityAssertionID: IOPMAssertionID = 0
    private var activityReleaseTask: Task<Void, Never>?

    private override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep(_:)),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake(_:)),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        isDisplayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    // MARK: Aserción del sistema

    /// Crea o libera la aserción que impide el reposo del sistema por inactividad.
    /// La pantalla puede seguir apagándose libremente.
    @discardableResult
    func setPreventSleep(_ enabled: Bool, reason: String = "Ghost: manteniendo el Mac despierto") -> Bool {
        if enabled {
            if sleepAssertionID != 0 {
                if reason != sleepAssertionReason {
                    _ = IOPMAssertionSetProperty(sleepAssertionID,
                                                 kIOPMAssertionNameKey as CFString,
                                                 reason as CFString)
                    sleepAssertionReason = reason
                }
                return true
            }

            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                NSLog("Ghost: IOPMAssertionCreateWithName falló (0x%08x)", result)
                return false
            }
            sleepAssertionID = assertionID
            sleepAssertionReason = reason
            isPreventingSleep = true
            return true
        }

        guard sleepAssertionID != 0 else { return true }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
        sleepAssertionReason = ""
        isPreventingSleep = false
        return true
    }

    /// Modo Sonámbulo: crea o libera la aserción que impide que la pantalla se apague.
    @discardableResult
    func setPreventDisplaySleep(_ enabled: Bool) -> Bool {
        if enabled {
            guard displayAssertionID == 0 else { return true }
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Ghost: Modo Sonámbulo (pantalla encendida)" as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                NSLog("Ghost: no se pudo crear la aserción de pantalla (0x%08x)", result)
                return false
            }
            displayAssertionID = assertionID
            isPreventingDisplaySleep = true
            return true
        }

        guard displayAssertionID != 0 else { return true }
        IOPMAssertionRelease(displayAssertionID)
        displayAssertionID = 0
        isPreventingDisplaySleep = false
        return true
    }

    func releaseAll() {
        setPreventDisplaySleep(false)
        setPreventSleep(false)
        releaseUserActivity()
    }

    // MARK: Pantalla

    /// Apaga todas las pantallas ahora mismo sin suspender el sistema.
    func sleepDisplayNow() {
        // Una aserción de actividad de usuario viva volvería a encender la pantalla.
        releaseUserActivity()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            Task { @MainActor in
                _ = GhostPowerManager.requestDisplayIdleViaIOKit()
            }
        }
        do {
            try process.run()
        } catch {
            _ = Self.requestDisplayIdleViaIOKit()
        }
    }

    /// Fallback IOKit: pide al IODisplayWrangler que pase a inactivo.
    static func requestDisplayIdleViaIOKit() -> Bool {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != 0 else { return false }
        defer { IOObjectRelease(wrangler) }
        return IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue) == kIOReturnSuccess
    }

    /// Enciende la pantalla declarando actividad de usuario local (sin eventos de teclado falsos).
    func wakeDisplay() {
        var assertionID = activityAssertionID
        let result = IOPMAssertionDeclareUserActivity(
            "Ghost: despertar pantalla" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        if result == kIOReturnSuccess {
            activityAssertionID = assertionID
            scheduleActivityRelease()
        } else {
            NSLog("Ghost: IOPMAssertionDeclareUserActivity falló (0x%08x); uso caffeinate -u", result)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-u", "-t", "2"]
            try? process.run()
        }
    }

    /// Tras unos segundos se suelta la actividad declarada para que la pantalla vuelva
    /// a obedecer el temporizador normal de "apagar pantalla" de macOS.
    private func scheduleActivityRelease() {
        activityReleaseTask?.cancel()
        activityReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseUserActivity()
        }
    }

    private func releaseUserActivity() {
        activityReleaseTask?.cancel()
        activityReleaseTask = nil
        guard activityAssertionID != 0 else { return }
        IOPMAssertionRelease(activityAssertionID)
        activityAssertionID = 0
    }

    // MARK: Notificaciones de pantalla

    @objc private func screensDidSleep(_ notification: Notification) {
        isDisplayAsleep = true
    }

    @objc private func screensDidWake(_ notification: Notification) {
        lastDisplayWakeAt = Date()
        isDisplayAsleep = false
    }
}
