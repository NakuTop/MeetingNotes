import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var transcriptionModelViewModel: TranscriptionModelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AudioDeviceSettingsView(viewModel: viewModel)

                AdaptiveGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("本地转录精度")
                            .font(.headline)

                        Picker(
                            "转录精度",
                            selection: $viewModel
                                .selectedTranscriptionQualityMode
                        ) {
                            ForEach(
                                TranscriptionQualityMode.allCases,
                                id: \.self
                            ) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(
                            viewModel.areTranscriptionControlsDisabled
                        )
                        .accessibilityIdentifier(
                            "settings.transcription.quality"
                        )

                        Text(
                            transcriptionModelViewModel
                                .descriptor(
                                    for: viewModel
                                        .selectedTranscriptionQualityMode
                                ).detail
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        ModelStatusView(
                            viewModel: transcriptionModelViewModel,
                            mode: viewModel.selectedTranscriptionQualityMode,
                            accessibilityIdentifier:
                                "settings.transcription.status",
                            showsRetryButton: false
                        )

                        if (
                            viewModel.selectedTranscriptionQualityMode
                                == .highAccuracy
                                && transcriptionModelViewModel
                                    .canDownload(
                                        mode: viewModel
                                            .selectedTranscriptionQualityMode
                                    )
                        ) || transcriptionModelViewModel.canRetry(
                            mode: viewModel.selectedTranscriptionQualityMode
                        ) {
                            HStack {
                                Spacer()
                                Button(
                                    transcriptionDownloadButtonTitle(
                                        for: viewModel
                                            .selectedTranscriptionQualityMode
                                    )
                                ) {
                                    let mode = viewModel
                                        .selectedTranscriptionQualityMode
                                    Task {
                                        await viewModel
                                            .refreshAudioControlAvailability()
                                        guard !viewModel
                                            .areTranscriptionControlsDisabled
                                        else { return }
                                        if transcriptionModelViewModel
                                            .canRetry(mode: mode) {
                                            await transcriptionModelViewModel
                                                .retry(mode: mode)
                                        } else {
                                            await transcriptionModelViewModel
                                                .download(mode: mode)
                                        }
                                    }
                                }
                                .disabled(
                                    viewModel.areTranscriptionControlsDisabled
                                        || transcriptionModelViewModel
                                            .status(
                                                for: viewModel
                                                    .selectedTranscriptionQualityMode
                                            ) == .downloading
                                )
                                .accessibilityIdentifier(
                                    "settings.transcription.download"
                                )
                            }
                        }

                        Text("切换后从下一场会议生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AdaptiveGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DeepSeek")
                            .font(.headline)

                        SecureField(
                            "输入新的 API Key",
                            text: $viewModel.deepSeekAPIKeyInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .accessibilityIdentifier("settings.deepseek.key")

                        CredentialPresenceView(
                            title: "API Key",
                            presence: viewModel.deepSeekCredential
                        )

                        HStack {
                            Picker("模型", selection: $viewModel.selectedModel) {
                                ForEach(viewModel.availableModels, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            .frame(maxWidth: .infinity)

                            Button("测试连接") {
                                Task {
                                    await viewModel.testDeepSeekConnection()
                                }
                            }
                            .disabled(viewModel.deepSeekConnection.isTesting)
                            .accessibilityIdentifier(
                                "settings.deepseek.testConnection"
                            )
                        }

                        ConnectionStateView(
                            state: viewModel.deepSeekConnection
                        )

                        HStack {
                            Spacer()
                            Button("清除 DeepSeek Key", role: .destructive) {
                                viewModel.clearDeepSeekCredential()
                            }
                            .disabled(viewModel.deepSeekCredential == .missing)
                        }
                    }
                }

                AdaptiveGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notion")
                            .font(.headline)

                        Toggle(
                            "启用 Notion 同步",
                            isOn: $viewModel.isNotionArchivingEnabled
                        )
                        .accessibilityIdentifier(
                            "settings.notion.archiveEnabled"
                        )

                        Text(
                            "本地内容会随时自动保存；只有在会议详情中点击“同步到 Notion”时才会更新 Notion 页面。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        SecureField(
                            "输入新的 Notion Token",
                            text: $viewModel.notionTokenInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .accessibilityIdentifier("settings.notion.token")

                        CredentialPresenceView(
                            title: "Token",
                            presence: viewModel.notionCredential
                        )

                        TextField(
                            "Notion 父页面链接",
                            text: $viewModel.notionParentPageURL
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.notion.pageURL")

                        HStack {
                            Text("集成必须已被邀请访问该父页面。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("测试连接") {
                                Task {
                                    await viewModel.testNotionConnection()
                                }
                            }
                            .disabled(viewModel.notionConnection.isTesting)
                            .accessibilityIdentifier(
                                "settings.notion.testConnection"
                            )
                        }

                        ConnectionStateView(state: viewModel.notionConnection)

                        HStack {
                            Spacer()
                            Button("清除 Notion Token", role: .destructive) {
                                viewModel.clearNotionCredential()
                            }
                            .disabled(viewModel.notionCredential == .missing)
                        }
                    }
                }

                AdaptiveGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("常用说话人")
                            .font(.headline)

                        Text("提前保存高频参会者姓名，会议中可直接选择，无需重复输入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField(
                                "输入姓名或角色",
                                text: $viewModel.newSpeakerName
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                viewModel.addFrequentSpeakerName()
                            }
                            .accessibilityIdentifier(
                                "settings.speakers.newName"
                            )

                            Button("添加") {
                                viewModel.addFrequentSpeakerName()
                            }
                            .disabled(
                                AppSettingsStore.normalizedSpeakerNames([
                                    viewModel.newSpeakerName
                                ]).isEmpty
                            )
                            .accessibilityIdentifier("settings.speakers.add")
                        }

                        if viewModel.frequentSpeakerNames.isEmpty {
                            Text("尚未添加常用说话人")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(minimum: 120),
                                        spacing: 8
                                    )
                                ],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(
                                    Array(
                                        viewModel.frequentSpeakerNames
                                            .enumerated()
                                    ),
                                    id: \.offset
                                ) { index, name in
                                    HStack(spacing: 6) {
                                        Text(name)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Button {
                                            viewModel
                                                .removeFrequentSpeakerName(name)
                                        } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("删除 \(name)")
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        .secondary.opacity(0.1),
                                        in: Capsule()
                                    )
                                    .accessibilityIdentifier(
                                        "settings.speakers.name.\(index)"
                                    )
                                }
                            }
                        }
                    }
                }

                AdaptiveGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("试验功能")
                            .font(.headline)

                        Toggle(
                            "FluidAudio 说话人分离",
                            isOn: $viewModel.isSpeakerDiarizationEnabled
                        )
                        .accessibilityIdentifier(
                            "settings.speakerDiarization.enabled"
                        )

                        Text(
                            "默认关闭，所有分离均在本地运行。首次使用可能需要下载模型，并会增加会后处理时间。录音中修改只影响下一场会议。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    ConnectionStateView(state: viewModel.saveState)
                    Spacer()
                    Button("保存设置") {
                        Task {
                            if await viewModel.save() {
                                transcriptionModelViewModel.selectedMode =
                                    viewModel
                                        .selectedTranscriptionQualityMode
                            }
                        }
                    }
                    .disabled(
                        viewModel.areTranscriptionControlsDisabled
                            || !transcriptionModelViewModel
                                .canPersistSelection(
                                    mode: viewModel
                                        .selectedTranscriptionQualityMode
                                )
                    )
                    .adaptivePrimaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.save")
                }
            }
            .padding(22)
        }
        .accessibilityIdentifier("settings.scroll")
        .frame(width: 620, height: 780)
        .task {
            viewModel.audioSettingsDidAppear()
            viewModel.load()
            await transcriptionModelViewModel.refreshStatuses()
            await viewModel.refreshAudioControlAvailability()
            await viewModel.refreshAudioDevices()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                await viewModel.refreshAudioControlAvailability()
            }
        }
        .onDisappear {
            viewModel.audioSettingsDidDisappear()
        }
    }

    private func transcriptionDownloadButtonTitle(
        for mode: TranscriptionQualityMode
    ) -> String {
        transcriptionModelViewModel.canRetry(mode: mode)
            ? "重试下载"
            : "下载高精度模型"
    }
}

private struct CredentialPresenceView: View {
    let title: String
    let presence: CredentialPresence

    var body: some View {
        switch presence {
        case .missing:
            Label("未保存 \(title)", systemImage: "key.slash")
                .foregroundStyle(.secondary)
        case let .saved(maskedValue):
            Label("已保存 \(title)：\(maskedValue)", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .textSelection(.disabled)
        }
    }
}

private struct ConnectionStateView: View {
    let state: ConnectionTestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试连接…")
            }
            .foregroundStyle(.secondary)
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
