import SwiftUI

/// SF Symbols del estado (barra de menú y cabecera del popover).
enum GhostIcon {
    static func symbol(isAwake: Bool, ghostMode: Bool, lockout: Bool) -> String {
        if lockout { return "battery.25percent" }
        if ghostMode { return "eye.slash.fill" }
        if isAwake { return "eye.fill" }
        return "eye"
    }
}

@MainActor
struct GhostMenuBarView: View {
    @ObservedObject var controller: GhostController
    @ObservedObject var settings: GhostSettings
    let openSettings: () -> Void
    let quit: () -> Void

    private let cardFill = Color.white.opacity(0.06)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            awakeCard
            ghostModeButton
            timerSection
            if !controller.triggerReasons.isEmpty {
                triggerChips
            }
            if let notice = controller.notice {
                noticeView(notice)
            }
            statsRow
            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(controller.isAwake ? Color.white.opacity(0.16) : cardFill)
                    .frame(width: 40, height: 40)
                Image(systemName: GhostIcon.symbol(isAwake: controller.isAwake,
                                                   ghostMode: controller.ghostModeActive,
                                                   lockout: controller.batteryLockout))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Ghost")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(controller.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let end = controller.sessionEndsAt {
                Text(end, style: .timer)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Mantener despierto

    private var awakeCard: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mantener Mac despierto")
                    .font(.system(size: 13, weight: .medium))
                Text("El sistema no dormirá; la pantalla sí puede apagarse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { controller.manualAwake },
                set: { $0 ? controller.enable(.indefinite) : controller.disable() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardFill))
    }

    // MARK: Modo Ghost

    private var ghostModeButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { controller.toggleGhostMode() }) {
                HStack(spacing: 10) {
                    Image(systemName: controller.ghostModeActive ? "sun.max.fill" : "moon.stars.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(controller.ghostModeActive ? "Salir del Modo Ghost" : "Activar Modo Ghost")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(settings.hotkey.display)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(white: 0.24), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(settings.useBlackCurtain
                 ? "Cubre las pantallas con negro; el Mac sigue trabajando."
                 : "Apaga la pantalla al instante; el Mac sigue trabajando.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    // MARK: Temporizador

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPORIZADOR")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(GhostDuration.presets) { duration in
                    let selected = controller.manualAwake && controller.selectedDuration == duration
                    Button {
                        selected ? controller.disable() : controller.enable(duration)
                    } label: {
                        Text(duration.shortLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.9))
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? Color.white.opacity(0.92) : cardFill)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(duration.minutes == nil ? "Sin límite" : "Mantener despierto \(duration.shortLabel)")
                }
            }
        }
    }

    // MARK: Triggers y avisos

    private var triggerChips: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            ForEach(controller.triggerReasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(cardFill))
            }
            Spacer(minLength: 0)
        }
    }

    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.notice = nil
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Estadísticas en vivo

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat(symbol: "cpu",
                 value: controller.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "—")
            Spacer()
            stat(symbol: "arrow.up.arrow.down",
                 value: controller.networkKBps.map(GhostFormat.rate) ?? "—")
            Spacer()
            stat(symbol: batterySymbol,
                 value: controller.battery.percent.map { "\($0)%" } ?? "AC")
        }
        .padding(.horizontal, 4)
    }

    private var batterySymbol: String {
        if !controller.battery.hasBattery { return "powerplug.fill" }
        return controller.battery.isOnAC ? "battery.100percent.bolt" : "battery.50percent"
    }

    private func stat(symbol: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
        }
    }

    // MARK: Pie

    private var footer: some View {
        HStack {
            Button("Ajustes…", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Salir de Ghost", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
