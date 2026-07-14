import SwiftUI

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    @State private var consentConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("会议记录，优先留在本机")
                        .font(.title2.bold())
                    Text("开始前请了解数据流向与录音责任。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                privacyRow(
                    symbol: "lock.macwindow",
                    title: "音频与本地转录保存在这台 Mac",
                    detail: "录音不会上传给 DeepSeek；模型在本机运行。"
                )
                privacyRow(
                    symbol: "sparkles",
                    title: "只有点击“总结并归档”才会联网",
                    detail: "转录文本会发送给 DeepSeek，并按你的设置写入 Notion。"
                )
                privacyRow(
                    symbol: "checkmark.shield",
                    title: "权限按需请求",
                    detail: "线下会议只需麦克风；在线会议还需屏幕与系统音频录制权限。"
                )
            }

            Toggle(isOn: $consentConfirmed) {
                Text("我会在录音前告知参会者，并确认已取得必要许可")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("onboarding.recordingConsent")

            HStack {
                Spacer()
                Button("了解并继续") {
                    state.completePrivacyAndConsent()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!consentConfirmed)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.complete")
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func privacyRow(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
