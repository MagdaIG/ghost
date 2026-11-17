import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Modelo de ajustes (UserDefaults: dev.ghost.Ghost)

@MainActor
final class GhostSettings: ObservableObject {
    static let shared = GhostSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkey = "hotkey"
        static let useBlackCurtain = "useBlackCurtain"
        static let batteryProtectionEnabled = "batteryProtectionEnabled"
        static let batteryThreshold = "batteryThreshold"
        static let appTriggerEnabled = "appTriggerEnabled"
        static let watchedApps = "watchedApps"
        static let cpuTriggerEnabled = "cpuTriggerEnabled"
        static let cpuThreshold = "cpuThreshold"
        static let networkTriggerEnabled = "networkTriggerEnabled"
        static let networkThresholdKBps = "networkThresholdKBps"
    }

    @Published var hotkey: GhostShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Key.hotkey) }
        }
    }
    @Published var useBlackCurtain: Bool {
        didSet { defaults.set(useBlackCurtain, forKey: Key.useBlackCurtain) }
    }
    @Published var batteryProtectionEnabled: Bool {
        didSet { defaults.set(batteryProtectionEnabled, forKey: Key.batteryProtectionEnabled) }
    }
    @Published var batteryThreshold: Int {
        didSet { defaults.set(batteryThreshold, forKey: Key.batteryThreshold) }
    }
    @Published var appTriggerEnabled: Bool {
        didSet { defaults.set(appTriggerEnabled, forKey: Key.appTriggerEnabled) }
    }
    @Published var watchedApps: [String] {
        didSet { defaults.set(watchedApps, forKey: Key.watchedApps) }
    }
    @Published var cpuTriggerEnabled: Bool {
        didSet { defaults.set(cpuTriggerEnabled, forKey: Key.cpuTriggerEnabled) }
    }
    @Published var cpuThreshold: Double {
        didSet { defaults.set(cpuThreshold, forKey: Key.cpuThreshold) }
    }
    @Published var networkTriggerEnabled: Bool {
        didSet { defaults.set(networkTriggerEnabled, forKey: Key.networkTriggerEnabled) }
    }
    @Published var networkThresholdKBps: Double {
        didSet { defaults.set(networkThresholdKBps, forKey: Key.networkThresholdKBps) }
    }

    private init() {
        defaults.register(defaults: [
            Key.useBlackCurtain: false,
            Key.batteryProtectionEnabled: true,
            Key.batteryThreshold: 20,
            Key.appTriggerEnabled: true,
            Key.watchedApps: [String](),
            Key.cpuTriggerEnabled: false,
            Key.cpuThreshold: 60.0,
            Key.networkTriggerEnabled: false,
            Key.networkThresholdKBps: 500.0
        ])

        if let data = defaults.data(forKey: Key.hotkey),
           let stored = try? JSONDecoder().decode(GhostShortcut.self, from: data) {
            hotkey = stored
        } else {
            hotkey = .default
        }
        useBlackCurtain = defaults.bool(forKey: Key.useBlackCurtain)
        batteryProtectionEnabled = defaults.bool(forKey: Key.batteryProtectionEnabled)
        batteryThreshold = defaults.integer(forKey: Key.batteryThreshold)
        appTriggerEnabled = defaults.bool(forKey: Key.appTriggerEnabled)
        watchedApps = defaults.stringArray(forKey: Key.watchedApps) ?? []
        cpuTriggerEnabled = defaults.bool(forKey: Key.cpuTriggerEnabled)
        cpuThreshold = defaults.double(forKey: Key.cpuThreshold)
        networkTriggerEnabled = defaults.bool(forKey: Key.networkTriggerEnabled)
        networkThresholdKBps = defaults.double(forKey: Key.networkThresholdKBps)
    }

    func addWatchedApp(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !watchedApps.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        watchedApps.append(trimmed)
    }

    func removeWatchedApp(_ identifier: String) {
        watchedApps.removeAll { $0 == identifier }
    }
}

// MARK: - Inicio de sesión (ServiceManagement)

@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    /// Devuelve un mensaje de error legible o nil si todo fue bien.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "No se pudo cambiar el inicio automático: \(error.localizedDescription). " +
                "Asegúrate de que Ghost esté en /Applications."
        }
    }
}

// MARK: - Ventana de ajustes

@MainActor
struct GhostSettingsView: View {
    @ObservedObject var settings: GhostSettings
    @ObservedObject var controller: GhostController

    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var newAppIdentifier = ""

    private struct NetworkPreset: Identifiable {
        let label: String
        let value: Double
        var id: Double { value }
    }

    private struct SuggestedApp: Identifiable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    private static let networkPresets: [NetworkPreset] = [
        NetworkPreset(label: "100 KB/s", value: 100),
        NetworkPreset(label: "500 KB/s", value: 500),
        NetworkPreset(label: "1 MB/s", value: 1024),
        NetworkPreset(label: "5 MB/s", value: 5120),
        NetworkPreset(label: "10 MB/s", value: 10240)
    ]

    private static let suggestedApps: [SuggestedApp] = [
        SuggestedApp(name: "Docker", bundleID: "com.docker.docker"),
        SuggestedApp(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        SuggestedApp(name: "Transmission", bundleID: "org.m0k.transmission"),
        SuggestedApp(name: "qBittorrent", bundleID: "org.qbittorrent.qBittorrent"),
        SuggestedApp(name: "OrbStack", bundleID: "dev.kdrag0n.MacVirt")
    ]

    var body: some View {
        Form {
            generalSection
            batterySection
            triggersSection
            automationSection
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
        .onAppear { loginStatus = LoginItem.status }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle("Abrir Ghost al iniciar sesión", isOn: Binding(
                get: { loginStatus == .enabled },
                set: { newValue in
                    loginError = LoginItem.set(newValue)
                    loginStatus = LoginItem.status
                }
            ))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("macOS necesita tu aprobación en Ítems de inicio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Abrir Ajustes") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.orange)
            }

            LabeledContent("Atajo global") {
                ShortcutRecorder(settings: settings)
            }
            if !controller.hotkeyRegistered {
                Label("Otra app ya usa \(settings.hotkey.display). Elige otra combinación.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if GhostHotkeyManager.isSecureInputActive {
                Label("Hay una app con «Entrada segura» activa (p. ej. un campo de contraseña o Terminal con Secure Keyboard Entry). Mientras siga activa, macOS bloquea todos los atajos globales.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Modo Ghost", selection: $settings.useBlackCurtain) {
                Text("Apagar pantalla").tag(false)
                Text("Cortina negra").tag(true)
            }
            Text(settings.useBlackCurtain
                 ? "Cubre todas las pantallas con negro puro. Úsalo con Compartir Pantalla/VNC o con monitores que no se apagan."
                 : "Apaga físicamente los monitores (pmset displaysleepnow). El Mac sigue trabajando.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("General")
        } footer: {
            Text("No necesita permisos de Accesibilidad: el atajo se intercepta con Carbon y nunca llega a otras apps.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Batería

    private var batterySection: some View {
        Section("Protección de batería") {
            Toggle("Desactivar Ghost con batería baja", isOn: $settings.batteryProtectionEnabled)
            Stepper(value: $settings.batteryThreshold, in: 5...80, step: 5) {
                Text("Umbral: \(settings.batteryThreshold)% sin cargador")
            }
            .disabled(!settings.batteryProtectionEnabled)
            LabeledContent("Ahora", value: controller.battery.summary)
                .font(.caption)
        }
    }

    // MARK: Triggers

    private var triggersSection: some View {
        Section {
            Toggle("Mantener despierto mientras estas apps estén abiertas", isOn: $settings.appTriggerEnabled)

            if settings.watchedApps.isEmpty {
                Text("Ninguna app vigilada todavía.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.watchedApps, id: \.self) { entry in
                    HStack(spacing: 8) {
                        appIcon(for: entry)
                        Text(displayName(for: entry))
                        if displayName(for: entry) != entry {
                            Text(entry).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.removeWatchedApp(entry)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Quitar")
                    }
                }
            }

            HStack {
                Menu("Añadir app abierta") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            settings.addWatchedApp(app.bundleIdentifier ?? app.localizedName ?? "")
                        }
                    }
                }
                .fixedSize()
                TextField("", text: $newAppIdentifier, prompt: Text("Bundle ID o nombre"))
                    .labelsHidden()
                    .onSubmit(addTypedApp)
                Button("Añadir", action: addTypedApp)
                    .disabled(newAppIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let pendingSuggestions = Self.suggestedApps.filter { suggestion in
                !settings.watchedApps.contains { $0.caseInsensitiveCompare(suggestion.bundleID) == .orderedSame }
            }
            if !pendingSuggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Sugerencias:").font(.caption).foregroundStyle(.secondary)
                    ForEach(pendingSuggestions) { suggestion in
                        Button(suggestion.name) { settings.addWatchedApp(suggestion.bundleID) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }

            Toggle("Mantener despierto con CPU alta", isOn: $settings.cpuTriggerEnabled)
            HStack {
                Slider(value: $settings.cpuThreshold, in: 10...100, step: 5)
                Text("≥ \(Int(settings.cpuThreshold))%")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            .disabled(!settings.cpuTriggerEnabled)
            Text("Uso actual: " + (controller.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "midiendo…"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Mantener despierto con tráfico de red alto", isOn: $settings.networkTriggerEnabled)
            Picker("Umbral de red", selection: $settings.networkThresholdKBps) {
                ForEach(Self.networkPresets) { preset in
                    Text(preset.label).tag(preset.value)
                }
            }
            .disabled(!settings.networkTriggerEnabled)
            Text("Tráfico actual: " + (controller.networkKBps.map(GhostFormat.rate) ?? "midiendo…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Triggers inteligentes")
        } footer: {
            Text("Los triggers de CPU y red se mantienen \(Int(GhostController.triggerCooldown)) s después de bajar del umbral para no cortar descargas con picos irregulares. Se miden cada \(Int(GhostController.monitorInterval)) s.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: CLI y Atajos

    private var automationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([
                    "ghost on            # despierto sin límite",
                    "ghost on 2h         # despierto 2 horas",
                    "ghost sleep         # Modo Ghost (apaga pantalla)",
                    "ghost wake          # enciende la pantalla",
                    "ghost off           # vuelve al reposo normal",
                    "ghost status        # estado actual"
                ], id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)

            LabeledContent("Comando instalado") {
                Text(cliPath ?? "No encontrado (ejecuta ./install.sh)")
                    .font(.caption)
                    .foregroundStyle(cliPath == nil ? Color.orange : Color.secondary)
            }

            HStack {
                Text("Atajos de Apple: acción «Abrir URL» con")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ghost://toggle").font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ghost://toggle", forType: .string)
                }
                .controlSize(.small)
            }
        } header: {
            Text("Terminal y Atajos")
        } footer: {
            Text("URLs disponibles: ghost://on?minutes=30, ghost://off, ghost://toggle, ghost://sleep, ghost://wake, ghost://curtain, ghost://settings")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Helpers

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private var cliPath: String? {
        let candidates = ["/usr/local/bin/ghost", NSHomeDirectory() + "/.local/bin/ghost"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func addTypedApp() {
        settings.addWatchedApp(newAppIdentifier)
        newAppIdentifier = ""
    }

    private func displayName(for entry: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry
    }

    @ViewBuilder
    private func appIcon(for entry: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grabador de atajos

@MainActor
struct ShortcutRecorder: View {
    @ObservedObject var settings: GhostSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(isRecording ? "Pulsa la combinación…" : settings.hotkey.display)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if settings.hotkey != .default && !isRecording {
                Button("Restablecer") { settings.hotkey = .default }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Sin desregistrar, Carbon consumiría la combinación actual antes que la ventana.
        GhostHotkeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if let shortcut = GhostShortcut(event: event) {
                settings.hotkey = shortcut
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        GhostHotkeyManager.shared.register(settings.hotkey)
    }
}

// MARK: - Formato

enum GhostFormat {
    static func rate(_ kilobytesPerSecond: Double) -> String {
        if kilobytesPerSecond >= 1024 {
            return String(format: "%.1f MB/s", kilobytesPerSecond / 1024)
        }
        return String(format: "%.0f KB/s", kilobytesPerSecond)
    }
}
