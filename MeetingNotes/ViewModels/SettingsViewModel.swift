import Foundation
import Observation

enum CredentialPresence: Equatable, Sendable {
    case missing
    case saved(maskedValue: String)
}

enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case succeeded(message: String)
    case failed(message: String)

    var isTesting: Bool {
        self == .testing
    }
}

protocol DeepSeekConnectionTesting: Sendable {
    func testConnection(apiKey: String) async throws -> [String]
}

struct LiveDeepSeekConnectionTester: DeepSeekConnectionTesting {
    let httpClient: any HTTPClient

    func testConnection(apiKey: String) async throws -> [String] {
        try await DeepSeekClient(
            apiKey: apiKey,
            httpClient: httpClient
        ).testConnection()
    }
}

protocol NotionConnectionTesting: Sendable {
    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult
}

struct LiveNotionConnectionTester: NotionConnectionTesting {
    let httpClient: any HTTPClient

    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        try await NotionClient(
            token: token,
            httpClient: httpClient
        ).testConnection(parentPageID: parentPageID)
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    private let credentialStore: any CredentialStore
    private let settingsStore: AppSettingsStore
    private let deepSeekTester: any DeepSeekConnectionTesting
    private let notionTester: any NotionConnectionTesting

    var deepSeekAPIKeyInput = ""
    var notionTokenInput = ""
    var selectedModel = AppSettingsStore.defaultDeepSeekModel
    var notionParentPageURL = ""

    private(set) var availableModels = [
        AppSettingsStore.defaultDeepSeekModel
    ]
    private(set) var deepSeekCredential: CredentialPresence = .missing
    private(set) var notionCredential: CredentialPresence = .missing
    private(set) var deepSeekConnection: ConnectionTestState = .idle
    private(set) var notionConnection: ConnectionTestState = .idle
    private(set) var saveState: ConnectionTestState = .idle

    init(
        credentialStore: any CredentialStore,
        settingsStore: AppSettingsStore,
        deepSeekTester: any DeepSeekConnectionTesting,
        notionTester: any NotionConnectionTesting
    ) {
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.deepSeekTester = deepSeekTester
        self.notionTester = notionTester
    }

    func load() {
        deepSeekAPIKeyInput = ""
        notionTokenInput = ""
        deepSeekConnection = .idle
        notionConnection = .idle
        selectedModel = settingsStore.deepSeekModel
        notionParentPageURL = settingsStore.notionParentPageURL
        if !availableModels.contains(selectedModel) {
            availableModels.append(selectedModel)
        }
        availableModels = Array(Set(availableModels)).sorted()

        do {
            try refreshCredentialPresence()
            saveState = .idle
        } catch {
            saveState = .failed(
                message: "无法读取钥匙串，请解锁登录钥匙串后重试。"
            )
        }
    }

    func save() {
        let deepSeekInput = deepSeekAPIKeyInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let notionInput = notionTokenInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        do {
            if !deepSeekInput.isEmpty {
                try credentialStore.save(
                    deepSeekInput,
                    for: .deepSeekAPIKey
                )
            }
            if !notionInput.isEmpty {
                try credentialStore.save(
                    notionInput,
                    for: .notionToken
                )
            }
            settingsStore.deepSeekModel = selectedModel
            settingsStore.notionParentPageURL = notionParentPageURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            notionParentPageURL = settingsStore.notionParentPageURL
            selectedModel = settingsStore.deepSeekModel
            deepSeekAPIKeyInput = ""
            notionTokenInput = ""
            try refreshCredentialPresence()
            saveState = .succeeded(message: "设置已安全保存")
        } catch {
            saveState = .failed(
                message: "保存失败，请确认钥匙串可用后重试。"
            )
        }
    }

    func testDeepSeekConnection() async {
        guard !deepSeekConnection.isTesting else { return }

        let input = deepSeekAPIKeyInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let apiKey: String
        do {
            if !input.isEmpty {
                apiKey = input
            } else if let saved = try credentialStore.value(
                for: .deepSeekAPIKey
            ) {
                apiKey = saved
            } else {
                deepSeekConnection = .failed(
                    message: "请输入 DeepSeek API Key，或先保存已有 Key。"
                )
                return
            }
        } catch {
            deepSeekConnection = .failed(
                message: "无法读取已保存的 API Key，请检查钥匙串。"
            )
            return
        }

        deepSeekConnection = .testing
        do {
            let models = try await deepSeekTester.testConnection(apiKey: apiKey)
            availableModels = Array(Set(models)).sorted()
            if availableModels.isEmpty {
                availableModels = [selectedModel]
            } else if !availableModels.contains(selectedModel),
                      let first = availableModels.first {
                selectedModel = first
            }
            deepSeekConnection = .succeeded(
                message: "连接成功，发现 \(models.count) 个模型"
            )
        } catch {
            deepSeekConnection = .failed(
                message: Self.deepSeekMessage(for: error)
            )
        }
    }

    func testNotionConnection() async {
        guard !notionConnection.isTesting else { return }

        let input = notionTokenInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token: String
        do {
            if !input.isEmpty {
                token = input
            } else if let saved = try credentialStore.value(for: .notionToken) {
                token = saved
            } else {
                notionConnection = .failed(
                    message: "请输入 Notion Token，或先保存已有 Token。"
                )
                return
            }
        } catch {
            notionConnection = .failed(
                message: "无法读取已保存的 Notion Token，请检查钥匙串。"
            )
            return
        }

        guard let parentPageID = NotionPageLinkParser.parse(
            notionParentPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            notionConnection = .failed(
                message: "请输入有效的 Notion 父页面链接。"
            )
            return
        }

        notionConnection = .testing
        do {
            let result = try await notionTester.testConnection(
                token: token,
                parentPageID: parentPageID
            )
            notionConnection = .succeeded(
                message: "连接成功：\(result.parentPageTitle)"
            )
        } catch {
            notionConnection = .failed(
                message: Self.notionMessage(for: error)
            )
        }
    }

    func clearDeepSeekCredential() {
        do {
            try credentialStore.delete(.deepSeekAPIKey)
            deepSeekAPIKeyInput = ""
            deepSeekCredential = .missing
            deepSeekConnection = .idle
        } catch {
            saveState = .failed(message: "无法清除 DeepSeek API Key。")
        }
    }

    func clearNotionCredential() {
        do {
            try credentialStore.delete(.notionToken)
            notionTokenInput = ""
            notionCredential = .missing
            notionConnection = .idle
        } catch {
            saveState = .failed(message: "无法清除 Notion Token。")
        }
    }

    private func refreshCredentialPresence() throws {
        deepSeekCredential = try presence(for: .deepSeekAPIKey)
        notionCredential = try presence(for: .notionToken)
    }

    private func presence(for key: CredentialKey) throws -> CredentialPresence {
        guard let value = try credentialStore.value(for: key) else {
            return .missing
        }
        return .saved(maskedValue: CredentialMask.mask(value))
    }

    private static func deepSeekMessage(for error: Error) -> String {
        switch error as? DeepSeekClientError {
        case .unauthorized:
            "API Key 无效或无权限，请检查后重试。"
        case .rateLimited:
            "DeepSeek 请求过于频繁，请稍后重试。"
        case .timeout:
            "DeepSeek 连接超时，请检查网络后重试。"
        case .serviceUnavailable, .server:
            "DeepSeek 服务暂时不可用，请稍后重试。"
        case .transport:
            "无法连接 DeepSeek，请检查网络。"
        default:
            "DeepSeek 返回了无法识别的响应，请稍后重试。"
        }
    }

    private static func notionMessage(for error: Error) -> String {
        switch error as? NotionClientError {
        case .unauthorized:
            "Notion Token 无效，请检查后重试。"
        case .forbidden:
            "集成无权访问该页面，请在 Notion 中共享页面给集成。"
        case .pageNotFound:
            "找不到该 Notion 页面，请检查链接和共享权限。"
        case .rateLimited:
            "Notion 请求过于频繁，请稍后重试。"
        case .timeout:
            "Notion 连接超时，请检查网络后重试。"
        case .server:
            "Notion 服务暂时不可用，请稍后重试。"
        case .transport:
            "无法连接 Notion，请检查网络。"
        default:
            "Notion 返回了无法识别的响应，请稍后重试。"
        }
    }
}
