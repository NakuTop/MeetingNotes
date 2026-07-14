import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("DeepSeek") {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.top, 6)
                }

                GroupBox("Notion") {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.top, 6)
                }

                HStack(spacing: 12) {
                    ConnectionStateView(state: viewModel.saveState)
                    Spacer()
                    Button("保存设置") {
                        viewModel.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.save")
                }
            }
            .padding(22)
        }
        .frame(width: 560, height: 640)
        .task {
            viewModel.load()
        }
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
