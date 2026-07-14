import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testSaveWritesSecretsToCredentialStoreAndNonSecretsToSettings() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.deepSeekAPIKeyInput = "  sk-deepseek-123456  "
        viewModel.notionTokenInput = "secret_notion_987654"
        viewModel.selectedModel = "deepseek-reasoner"
        viewModel.notionParentPageURL = " https://www.notion.so/Parent-1234567890abcdef1234567890abcdef "

        viewModel.save()

        XCTAssertEqual(
            try fixture.credentials.value(for: .deepSeekAPIKey),
            "sk-deepseek-123456"
        )
        XCTAssertEqual(
            try fixture.credentials.value(for: .notionToken),
            "secret_notion_987654"
        )
        XCTAssertEqual(fixture.settings.deepSeekModel, "deepseek-reasoner")
        XCTAssertEqual(
            fixture.settings.notionParentPageURL,
            "https://www.notion.so/Parent-1234567890abcdef1234567890abcdef"
        )
        XCTAssertEqual(viewModel.deepSeekAPIKeyInput, "")
        XCTAssertEqual(viewModel.notionTokenInput, "")
        XCTAssertEqual(
            viewModel.deepSeekCredential,
            .saved(maskedValue: CredentialMask.mask("sk-deepseek-123456"))
        )
        XCTAssertEqual(
            viewModel.notionCredential,
            .saved(maskedValue: CredentialMask.mask("secret_notion_987654"))
        )
    }

    func testReloadShowsOnlyMaskedPresenceAndNeverHydratesSecretInputs() throws {
        let fixture = try makeFixture()
        try fixture.credentials.save(
            "secret-key-must-not-return",
            for: .deepSeekAPIKey
        )
        try fixture.credentials.save(
            "secret-token-must-not-return",
            for: .notionToken
        )

        fixture.viewModel.load()

        XCTAssertEqual(fixture.viewModel.deepSeekAPIKeyInput, "")
        XCTAssertEqual(fixture.viewModel.notionTokenInput, "")
        XCTAssertEqual(
            fixture.viewModel.deepSeekCredential,
            .saved(maskedValue: CredentialMask.mask("secret-key-must-not-return"))
        )
        XCTAssertEqual(
            fixture.viewModel.notionCredential,
            .saved(maskedValue: CredentialMask.mask("secret-token-must-not-return"))
        )
    }

    func testDeepSeekConnectionPrefersCurrentInputAndUpdatesModelList() async throws {
        let tester = RecordingDeepSeekTester(
            result: .success(["deepseek-chat", "deepseek-reasoner"])
        )
        let fixture = try makeFixture(deepSeekTester: tester)
        try fixture.credentials.save("saved-key", for: .deepSeekAPIKey)
        fixture.viewModel.deepSeekAPIKeyInput = "current-key"
        fixture.viewModel.selectedModel = "unknown-model"

        await fixture.viewModel.testDeepSeekConnection()

        let testedAPIKeys = await tester.apiKeys()
        XCTAssertEqual(testedAPIKeys, ["current-key"])
        XCTAssertEqual(
            fixture.viewModel.availableModels,
            ["deepseek-chat", "deepseek-reasoner"]
        )
        XCTAssertEqual(fixture.viewModel.selectedModel, "deepseek-chat")
        XCTAssertEqual(
            fixture.viewModel.deepSeekConnection,
            .succeeded(message: "连接成功，发现 2 个模型")
        )
    }

    func testDeepSeekConnectionFallsBackToSavedKey() async throws {
        let tester = RecordingDeepSeekTester(
            result: .success(["deepseek-chat"])
        )
        let fixture = try makeFixture(deepSeekTester: tester)
        try fixture.credentials.save("saved-key", for: .deepSeekAPIKey)

        await fixture.viewModel.testDeepSeekConnection()

        let testedAPIKeys = await tester.apiKeys()
        XCTAssertEqual(testedAPIKeys, ["saved-key"])
    }

    func testNotionConnectionValidatesTokenAndPageAndShowsParentTitle() async throws {
        let parentID = try XCTUnwrap(
            UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef")
        )
        let tester = RecordingNotionTester(
            result: .success(
                NotionConnectionResult(
                    userID: "bot-id",
                    userName: "Meeting Bot",
                    parentPage: NotionPageReference(
                        id: parentID.uuidString,
                        url: "https://www.notion.so/parent"
                    ),
                    parentPageTitle: "团队会议库"
                )
            )
        )
        let fixture = try makeFixture(notionTester: tester)
        fixture.viewModel.notionTokenInput = "current-notion-token"
        fixture.viewModel.notionParentPageURL =
            "https://www.notion.so/Team-1234567890abcdef1234567890abcdef"

        await fixture.viewModel.testNotionConnection()

        let calls = await tester.calls()
        XCTAssertEqual(calls.map(\.token), ["current-notion-token"])
        XCTAssertEqual(calls.map(\.parentPageID), [parentID])
        XCTAssertEqual(
            fixture.viewModel.notionConnection,
            .succeeded(message: "连接成功：团队会议库")
        )
    }

    func testClearDeletesCredentialsIndependently() throws {
        let fixture = try makeFixture()
        try fixture.credentials.save("deepseek", for: .deepSeekAPIKey)
        try fixture.credentials.save("notion", for: .notionToken)
        fixture.viewModel.load()

        fixture.viewModel.clearDeepSeekCredential()

        XCTAssertNil(try fixture.credentials.value(for: .deepSeekAPIKey))
        XCTAssertEqual(
            try fixture.credentials.value(for: .notionToken),
            "notion"
        )
        XCTAssertEqual(fixture.viewModel.deepSeekCredential, .missing)

        fixture.viewModel.clearNotionCredential()

        XCTAssertNil(try fixture.credentials.value(for: .notionToken))
        XCTAssertEqual(fixture.viewModel.notionCredential, .missing)
    }

    func testConnectionPreventsDuplicateClicksAndErrorsNeverContainSecret() async throws {
        let tester = BlockingDeepSeekTester()
        let fixture = try makeFixture(deepSeekTester: tester)
        let secret = "must-never-appear-in-errors"
        fixture.viewModel.deepSeekAPIKeyInput = secret

        let first = Task {
            await fixture.viewModel.testDeepSeekConnection()
        }
        await tester.waitUntilStarted()
        let duplicate = Task {
            await fixture.viewModel.testDeepSeekConnection()
        }
        await duplicate.value
        let callCount = await tester.callCount()
        XCTAssertEqual(callCount, 1)

        await tester.finish(with: .failure(DeepSeekClientError.unauthorized))
        await first.value

        guard case let .failed(message) = fixture.viewModel.deepSeekConnection else {
            return XCTFail("Expected a failed connection state")
        }
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains("API Key"))
    }

    private func makeFixture(
        deepSeekTester: any DeepSeekConnectionTesting = RecordingDeepSeekTester(
            result: .success([])
        ),
        notionTester: any NotionConnectionTesting = RecordingNotionTester(
            result: .failure(NotionClientError.transport)
        )
    ) throws -> Fixture {
        let suiteName = "SettingsViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let credentials = InMemoryCredentialStore()
        let settings = AppSettingsStore(defaults: defaults)
        return Fixture(
            viewModel: SettingsViewModel(
                credentialStore: credentials,
                settingsStore: settings,
                deepSeekTester: deepSeekTester,
                notionTester: notionTester
            ),
            credentials: credentials,
            settings: settings
        )
    }

    private struct Fixture {
        let viewModel: SettingsViewModel
        let credentials: InMemoryCredentialStore
        let settings: AppSettingsStore
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: String] = [:]

    func value(for key: CredentialKey) throws -> String? {
        values[key]
    }

    func save(_ value: String, for key: CredentialKey) throws {
        values[key] = value
    }

    func delete(_ key: CredentialKey) throws {
        values[key] = nil
    }
}

private actor RecordingDeepSeekTester: DeepSeekConnectionTesting {
    private let result: Result<[String], Error>
    private var recordedAPIKeys: [String] = []

    init(result: Result<[String], Error>) {
        self.result = result
    }

    func testConnection(apiKey: String) async throws -> [String] {
        recordedAPIKeys.append(apiKey)
        return try result.get()
    }

    func apiKeys() -> [String] {
        recordedAPIKeys
    }
}

private actor RecordingNotionTester: NotionConnectionTesting {
    struct Call: Equatable, Sendable {
        let token: String
        let parentPageID: UUID
    }

    private let result: Result<NotionConnectionResult, Error>
    private var recordedCalls: [Call] = []

    init(result: Result<NotionConnectionResult, Error>) {
        self.result = result
    }

    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        recordedCalls.append(Call(token: token, parentPageID: parentPageID))
        return try result.get()
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private actor BlockingDeepSeekTester: DeepSeekConnectionTesting {
    private var started = false
    private var calls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<[String], Error>?

    func testConnection(apiKey: String) async throws -> [String] {
        _ = apiKey
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls
    }

    func finish(with result: Result<[String], Error>) {
        guard let resultContinuation else { return }
        self.resultContinuation = nil
        resultContinuation.resume(with: result)
    }
}
