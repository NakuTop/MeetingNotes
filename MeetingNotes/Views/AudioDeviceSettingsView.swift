import SwiftUI

struct AudioDeviceSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    private let privacySettingsOpener: any PrivacySettingsOpening

    @State private var privacySettingsError: String?
    @State private var reviewedPreviewJSON: String?

    init(
        viewModel: SettingsViewModel,
        privacySettingsOpener: any PrivacySettingsOpening =
            PrivacySettingsOpener()
    ) {
        self.viewModel = viewModel
        self.privacySettingsOpener = privacySettingsOpener
    }

    var body: some View {
        AdaptiveGlassCard(tint: .blue.opacity(0.04)) {
            VStack(alignment: .leading, spacing: 14) {
                header
                deviceSelectors

                if let message = viewModel.audioDeviceMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                compatibilityStatus

                permissionRepairButtons
                Divider()
                diagnosticWorkflow
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("音频设备与智能诊断")
                    .font(.headline)
                Text("仅控制 MeetingNotes，不会修改 macOS 的全局音频设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await viewModel.refreshAudioControlAvailability()
                    await viewModel.refreshAudioDevices()
                }
            } label: {
                if viewModel.isRefreshingAudioDevices {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
            }
            .disabled(
                viewModel.isRefreshingAudioDevices
                    || viewModel.areAudioControlsDisabled
                    || hasActiveAudioOperation
            )
        }
    }

    private var deviceSelectors: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Picker(
                    "输入设备",
                    selection: $viewModel.selectedInputDeviceID
                ) {
                    Text("跟随系统默认").tag(String?.none)
                    if let missingInputDeviceID {
                        Text("已保存设备（不可用）")
                            .tag(Optional(missingInputDeviceID))
                    }
                    ForEach(viewModel.audioDevices.inputs) { device in
                        Text(inputDeviceLabel(device))
                            .tag(Optional(device.id))
                    }
                }
                .accessibilityIdentifier("settings.audio.inputPicker")

                Button(inputTestButtonTitle) {
                    Task {
                        await viewModel.testSelectedInput()
                    }
                }
                .disabled(
                    viewModel.areAudioControlsDisabled
                        || hasActiveAudioOperation
                )
                .accessibilityIdentifier("settings.audio.inputTest")
            }

            inputTestStatus

            HStack(alignment: .center, spacing: 10) {
                Picker(
                    "输出设备",
                    selection: $viewModel.selectedOutputDeviceID
                ) {
                    Text("跟随系统默认").tag(String?.none)
                    if let missingOutputDeviceID {
                        Text("已保存设备（不可用）")
                            .tag(Optional(missingOutputDeviceID))
                    }
                    ForEach(viewModel.audioDevices.outputs) { device in
                        Text(outputDeviceLabel(device))
                            .tag(Optional(device.id))
                    }
                }
                .accessibilityIdentifier("settings.audio.outputPicker")

                Button(outputTestButtonTitle) {
                    Task {
                        await viewModel.testSelectedOutput()
                    }
                }
                .disabled(
                    viewModel.areAudioControlsDisabled
                        || hasActiveAudioOperation
                )
                .accessibilityIdentifier("settings.audio.outputTest")
            }

            outputTestStatus
        }
        .disabled(
            viewModel.areAudioControlsDisabled || hasActiveAudioOperation
        )
    }

    @ViewBuilder
    private var compatibilityStatus: some View {
        if viewModel.isMicrophoneRecovering {
            Label(
                "正在重新连接麦克风…",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else if viewModel.isCoreAudioFallbackActive {
            Label(
                "已启用兼容录音模式（Core Audio）",
                systemImage: "waveform.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var inputTestStatus: some View {
        switch viewModel.audioInputTestState {
        case .idle:
            EmptyView()
        case let .testing(metrics):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("请对着所选麦克风说话…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: inputLevel(from: metrics), total: 1)
                    .accessibilityLabel("麦克风实时输入电平")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.audio.inputLevel")
        case let .completed(metrics):
            Label(
                audioLevelDescription(metrics.level),
                systemImage: metrics.level == .audible
                    ? "waveform.circle.fill"
                    : "waveform.slash"
            )
            .font(.caption)
            .foregroundStyle(metrics.level == .audible ? .green : .orange)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var outputTestStatus: some View {
        switch viewModel.audioOutputTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("正在播放测试音…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .succeeded(message):
            Label(message, systemImage: "speaker.wave.2.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var permissionRepairButtons: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("权限修复")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Button("打开麦克风权限") {
                    openPrivacySettings(.microphone)
                }
                .accessibilityIdentifier(
                    "settings.audio.microphonePrivacy"
                )

                Button("打开屏幕与系统音频权限") {
                    openPrivacySettings(.screenRecording)
                }
                .accessibilityIdentifier(
                    "settings.audio.screenRecordingPrivacy"
                )
            }
            .adaptiveSecondaryButtonStyle()

            Text("在线会议与智能诊断只捕获系统音频，无需共享桌面；截图仍需屏幕录制权限。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let privacySettingsError {
                Text(privacySettingsError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(viewModel.areAudioControlsDisabled)
    }

    private var diagnosticWorkflow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("智能诊断")
                        .font(.subheadline.weight(.semibold))
                    Text("使用与在线会议相同的 Core Audio 纯音频链路在本机检测；只有点击发送后，才会把下方预览内容交给 DeepSeek。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if shouldShowCancelButton {
                    Button("取消") {
                        Task {
                            reviewedPreviewJSON = nil
                            await viewModel.cancelAudioDiagnostic()
                            await viewModel.refreshAudioControlAvailability()
                        }
                    }
                    .accessibilityIdentifier("settings.audio.cancel")
                }
            }

            if viewModel.areAudioControlsDisabled {
                Label(
                    "录音进行中，设备测试与智能诊断暂不可用。",
                    systemImage: "record.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            diagnosticStateContent
        }
    }

    @ViewBuilder
    private var diagnosticStateContent: some View {
        switch viewModel.audioDiagnosticState {
        case .idle:
                Button {
                    Task {
                        reviewedPreviewJSON = nil
                        await viewModel.startSmartDiagnostic()
                    }
            } label: {
                Label("开始智能诊断", systemImage: "stethoscope")
            }
            .adaptivePrimaryButtonStyle()
            .disabled(
                viewModel.areAudioControlsDisabled
                    || isInputTesting
                    || isOutputTesting
            )
            .accessibilityIdentifier("settings.audio.smartDiagnostic")

        case let .running(phase):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(diagnosticPhaseDescription(phase))
            }
            .foregroundStyle(.secondary)

        case .awaitingOutputConfirmation:
            VStack(alignment: .leading, spacing: 8) {
                Text("刚才听到测试音了吗？")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Button("听到了") {
                        Task {
                            await viewModel.confirmOutputWasAudible(true)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.audio.outputHeardYes"
                    )

                    Button("没有听到") {
                        Task {
                            await viewModel.confirmOutputWasAudible(false)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.audio.outputHeardNo"
                    )
                }
            }
            .disabled(viewModel.areAudioControlsDisabled)

        case let .readyForUpload(preview):
            diagnosticPreview(preview, requiresConsent: true)
            sendToDeepSeekButton(
                title: "发送给 DeepSeek",
                preview: preview
            )

        case let .explaining(preview):
            diagnosticPreview(preview, requiresConsent: false)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("DeepSeek 正在生成简短解释…")
            }
            .foregroundStyle(.secondary)

        case let .completed(presentation):
            diagnosticPreview(
                presentation.local,
                requiresConsent: false
            )
            VStack(alignment: .leading, spacing: 5) {
                Label("DeepSeek 解释", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(presentation.issue)
                    .font(.subheadline)
                Text(presentation.solution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .failed(local, message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let local {
                diagnosticPreview(local, requiresConsent: true)
                sendToDeepSeekButton(
                    title: "重新发送给 DeepSeek",
                    preview: local
                )
            }
        }
    }

    private func diagnosticPreview(
        _ preview: AudioDiagnosticPreview,
        requiresConsent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("本地诊断", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(preview.localIssue)
                .font(.subheadline)
            Text(preview.localSolution)
                .font(.caption)
                .foregroundStyle(.secondary)
            GroupBox("将发送的数据预览") {
                Text(preview.allowlistedJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            if requiresConsent {
                Toggle(
                    "我已检查上述数据，同意发送给 DeepSeek",
                    isOn: previewConsentBinding(for: preview)
                )
                .toggleStyle(.checkbox)
                .accessibilityIdentifier(
                    "settings.audio.previewConsent"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.audio.preview")
    }

    private func sendToDeepSeekButton(
        title: String,
        preview: AudioDiagnosticPreview
    ) -> some View {
        Button(title) {
            Task {
                await viewModel.sendDiagnosticToDeepSeek()
            }
        }
        .adaptivePrimaryButtonStyle()
        .disabled(
            viewModel.areAudioControlsDisabled
                || reviewedPreviewJSON != preview.allowlistedJSON
        )
        .accessibilityIdentifier("settings.audio.sendToDeepSeek")
    }

    private func previewConsentBinding(
        for preview: AudioDiagnosticPreview
    ) -> Binding<Bool> {
        Binding(
            get: {
                reviewedPreviewJSON == preview.allowlistedJSON
            },
            set: { isReviewed in
                reviewedPreviewJSON = isReviewed
                    ? preview.allowlistedJSON
                    : nil
            }
        )
    }

    private var missingInputDeviceID: String? {
        guard let selectedID = viewModel.selectedInputDeviceID,
              !viewModel.audioDevices.inputs.contains(
                where: {
                    $0.id == selectedID
                        || $0.avFoundationUniqueID == selectedID
                        || $0.coreAudioUID == selectedID
                }
              ) else {
            return nil
        }
        return selectedID
    }

    private var missingOutputDeviceID: String? {
        guard let selectedID = viewModel.selectedOutputDeviceID,
              !viewModel.audioDevices.outputs.contains(
                where: { $0.id == selectedID }
              ) else {
            return nil
        }
        return selectedID
    }

    private var isInputTesting: Bool {
        if case .testing = viewModel.audioInputTestState { return true }
        return false
    }

    private var isOutputTesting: Bool {
        viewModel.audioOutputTestState == .testing
    }

    private var hasRunningDiagnostic: Bool {
        switch viewModel.audioDiagnosticState {
        case .idle, .readyForUpload, .completed, .failed:
            false
        case .running, .awaitingOutputConfirmation, .explaining:
            true
        }
    }

    private var hasActiveAudioOperation: Bool {
        isInputTesting || isOutputTesting || hasRunningDiagnostic
    }

    private var shouldShowCancelButton: Bool {
        if isInputTesting || isOutputTesting { return true }
        if case .idle = viewModel.audioDiagnosticState { return false }
        return true
    }

    private var inputTestButtonTitle: String {
        isInputTesting ? "正在测试" : "测试麦克风"
    }

    private var outputTestButtonTitle: String {
        isOutputTesting ? "正在播放" : "测试扬声器"
    }

    private func inputDeviceLabel(_ device: AudioInputDevice) -> String {
        var details: [String] = []
        if device.isSystemDefault { details.append("系统默认") }
        var backends: [String] = []
        if device.isAVFoundationAvailable {
            backends.append("AVFoundation")
        }
        if device.isCoreAudioAvailable {
            backends.append("Core Audio")
        }
        if !backends.isEmpty {
            details.append(backends.joined(separator: " + "))
        }
        if device.isInUseByAnotherApplication { details.append("正在被使用") }
        if !device.isUsable { details.append("不可用") }
        return details.isEmpty
            ? device.name
            : "\(device.name)（\(details.joined(separator: "、"))）"
    }

    private func outputDeviceLabel(_ device: AudioOutputDevice) -> String {
        var details: [String] = []
        if device.isSystemDefault { details.append("系统默认") }
        if !device.isUsable { details.append("不可用") }
        return details.isEmpty
            ? device.name
            : "\(device.name)（\(details.joined(separator: "、"))）"
    }

    private func inputLevel(from metrics: AudioSignalMetrics?) -> Double {
        min(max(metrics?.peak ?? 0, 0), 1)
    }

    private func audioLevelDescription(_ level: AudioLevelBand) -> String {
        switch level {
        case .audible: "麦克风声音正常"
        case .veryLow: "麦克风声音很小"
        case .silent: "麦克风持续静音"
        case .noFrames: "麦克风没有收到音频帧"
        }
    }

    private func diagnosticPhaseDescription(
        _ phase: AudioDiagnosticPhase
    ) -> String {
        switch phase {
        case .checkingPermissions: "正在检查权限与设备…"
        case .playingOutputTone: "正在播放输出测试音…"
        case .testingMicrophone: "正在检测麦克风信号…"
        case .testingSystemAudio: "正在检测系统音频（Core Audio）…"
        }
    }

    private func openPrivacySettings(
        _ destination: PrivacySettingsDestination
    ) {
        do {
            try privacySettingsOpener.open(destination)
            privacySettingsError = nil
        } catch {
            privacySettingsError = error.localizedDescription
        }
    }
}
