import SwiftUI

struct FloatingRecorderView: View {
    let isPaused: Bool
    let action: (FloatingControl) -> Void
    let controls = FloatingControl.allCases

    var body: some View {
        HStack(spacing: 8) {
            ForEach(controls) { control in
                let presentation = control.presentation(isPaused: isPaused)

                Button {
                    action(control)
                } label: {
                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(foregroundStyle(for: control))
                .background(
                    Circle()
                        .fill(.primary.opacity(0.08))
                )
                .disabled(control == .record)
                .opacity(control == .record && isPaused ? 0.45 : 1)
                .accessibilityLabel(Text(presentation.accessibilityLabel))
                .accessibilityIdentifier("floating.\(control.rawValue)")
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .padding(1)
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
