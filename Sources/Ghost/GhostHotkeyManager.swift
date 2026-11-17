import AppKit
import Carbon.HIToolbox

// MARK: - Por qué Carbon RegisterEventHotKey (y no CGEventTap)
//
// • RegisterEventHotKey es la API que usan Spotlight, Alfred o Raycast para atajos globales.
//   Cuando la combinación coincide, el WindowServer entrega el evento SOLO a Ghost:
//   la tecla queda consumida y nunca se escribe en la app activa.
// • No requiere permiso de Accesibilidad ni de Monitorización de entrada (TCC). Un
//   CGEventTap sí los exigiría y, con firma ad-hoc, macOS invalida el permiso en cada
//   recompilación. Por eso Ghost no pide ningún permiso.
// • Limitación: con "Entrada segura" activa (campos de contraseña, pantalla de bloqueo,
//   algunos gestores de contraseñas o terminales con Secure Keyboard Entry) macOS no
//   entrega atajos globales a nadie. GhostSettingsView avisa de ello.
// • Si la pantalla está apagada, pulsar cualquier tecla ya la enciende a nivel HID;
//   el atajo además restaura el estado de Ghost (sale del Modo Ghost) y la tecla no
//   llega a ninguna ventana.

struct GhostShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let `default` = GhostShortcut(
        keyCode: UInt32(kVK_ANSI_G),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "G"
    )

    var display: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }
}

extension GhostShortcut {
    /// Construye un atajo a partir de una pulsación. Exige ⌘, ⌃ o ⌥ para no secuestrar
    /// teclas normales de escritura.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }

        let label = GhostShortcut.label(for: event)
        guard !label.isEmpty else { return nil }

        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: label)
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Espacio", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19"
    ]

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeyLabels[Int(event.keyCode)] { return special }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        return characters.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

@MainActor
final class GhostHotkeyManager {
    static let shared = GhostHotkeyManager()

    /// Firma 'GHST' para reconocer nuestros eventos de hotkey.
    nonisolated static let signature: OSType = 0x4748_5354

    var onPressed: (@MainActor () -> Void)?
    private(set) var registeredShortcut: GhostShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Registra (o re-registra) el atajo global. Devuelve false si otra app ya lo usa.
    @discardableResult
    func register(_ shortcut: GhostShortcut) -> Bool {
        unregister()
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            NSLog("Ghost: no se pudo registrar el atajo %@ (OSStatus %d)", shortcut.display, status)
            return false
        }
        hotKeyRef = reference
        registeredShortcut = shortcut
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredShortcut = nil
    }

    /// true si alguna app tiene activa la Entrada Segura (bloquea todos los atajos globales).
    static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    fileprivate func handlePressed() {
        onPressed?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            ghostHotKeyEventHandler,
            1,
            &eventType,
            context,
            &handlerRef
        )
        if status != noErr {
            NSLog("Ghost: InstallEventHandler falló (OSStatus %d)", status)
        }
    }
}

/// Callback C de Carbon. Devolver noErr marca el evento como consumido.
private func ghostHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == GhostHotkeyManager.signature else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<GhostHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            manager.handlePressed()
        }
    }
    return noErr
}
