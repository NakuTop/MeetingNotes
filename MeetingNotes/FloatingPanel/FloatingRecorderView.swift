import SwiftUI

struct FloatingRecorderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPaused: Bool
    let action: (FloatingControl) -> Void
    let controls = FloatingControl.allCases

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    controlsRow(liquidGlass: true)
                        .padding(8)
                        .glassEffect(.regular, in: Capsule())
                }
            } else {
                controlsRow(liquidGlass: false)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.16), lineWidth: 0.5)
                    }
            }
        }
        .padding(1)
        .animation(
            AppVisualPolicy.motion(reduceMotion: reduceMotion).animation,
            value: isPaused
        )
    }

    private func controlsRow(liquidGlass: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(controls) { control in
                controlButton(control, liquidGlass: liquidGlass)
            }
        }
    }

    @ViewBuilder
    private func controlButton(
        _ control: FloatingControl,
        liquidGlass: Bool
    ) -> some View {
        let presentation = control.presentation(isPaused: isPaused)
        let button = Button {
            action(control)
        } label: {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
                .contentTransition(
                    reduceMotion ? .identity : .symbolEffect(.replace)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle(for: control))
        .disabled(control == .record)
        .opacity(control == .record && isPaused ? 0.45 : 1)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .accessibilityIdentifier("floating.\(control.rawValue)")

        if #available(macOS 26.0, *), liquidGlass {
            button.glassEffect(
                Glass.regular
                    .tint(foregroundStyle(for: control).opacity(0.18))
                    .interactive(control != .record),
                in: Circle()
            )
        } else {
            button.background(
                Circle()
                    .fill(.primary.opacity(0.08))
            )
        }
    }

    private func foregroundStyle(for control: FloatingControl) -> Color {
        switch control {
        case .record, .stop:
            .red
        case .pause:
            isPaused ? .green : .orange
        case .bookmark:
            .blue
        }
    }
}
