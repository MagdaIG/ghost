import AppKit
import Combine

// Modo "Cortina Negra":
// Cubre TODAS las pantallas con ventanas negras opacas por encima de todo (nivel salvapantallas).
// Útil cuando apagar físicamente el panel no es deseable: monitores externos que no
// respetan displaysleepnow, sesiones de Compartir Pantalla/VNC (apagar el display puede
// cortar o congelar la imagen remota) o cuando se quiere oscurecer sin perder la sesión.
// En OLED/Mini-LED, el negro puro apaga los píxeles/zonas, así que el desgaste es mínimo.
// No queda ningún elemento estático: el texto de ayuda se desvanece en 3 segundos.
//
// Salir: atajo global, Esc o doble clic.

@MainActor
final class BlackCurtainManager: ObservableObject {
    static let shared = BlackCurtainManager()

    @Published private(set) var isVisible = false
    var onDismissRequested: (@MainActor () -> Void)?

    private var windows: [CurtainWindow] = []
    private var hint = ""
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func show(hint: String) {
        guard !isVisible else { return }
        self.hint = hint
        isVisible = true
        rebuildWindows(showHint: true)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.rebuildWindows(showHint: false)
            }
        }

        NSApp.activate()
        windows.first?.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func rebuildWindows(showHint: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = CurtainWindow.make(for: screen, hint: showHint ? hint : nil)
            window.onDismiss = { [weak self] in
                self?.onDismissRequested?()
            }
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
    }
}

final class CurtainWindow: NSWindow {
    var onDismiss: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func make(for screen: NSScreen, hint: String?) -> CurtainWindow {
        let window = CurtainWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content

        if let hint {
            let label = NSTextField(labelWithString: hint)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = NSColor(white: 1, alpha: 0.35)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 1.2
                    label.animator().alphaValue = 0
                }
            }
        }
        return window
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onDismiss?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDismiss?()
        }
    }
}
