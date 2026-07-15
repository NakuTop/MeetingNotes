import Foundation

enum LaunchArguments {
    static let uiTesting = "-uiTesting"

    static func isUITesting(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(uiTesting)
    }
}

#if DEBUG
@MainActor
extension AppContainer {
    static func uiTesting() throws -> AppContainer {
        let repository = try MeetingRepository.inMemory()
        let recordingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeetingNotes-UITesting-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        let fileStore = MeetingFileStore(rootURL: recordingsURL)
        let credentials = EphemeralCredentialStore(
            deepSeekAPIKey: "ui-deepseek-key",
            notionToken: "ui-notion-token"
        )

        let suiteName = "MeetingNotes.UITesting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettingsStore(defaults: defaults)
        settings.deepSeekModel = "deepseek-chat"
        settings.notionParentPageURL =
            "https://www.notion.so/UI-Parent-1234567890abcdef1234567890abcdef"
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.completePrivacyAndConsent()

        return AppContainer(
            repository: repository,
            fileStore: fileStore,
            recordingsURL: recordingsURL,
            coordinatorDependencies: { panel in
                MeetingCoordinatorDependencies(
                    permissions: UITestPermissionAuthorizer(),
                    captureFactory: UITestCaptureFactory(),
                    writerFactory: UITestWriterFactory(),
                    transcriptionFactory: UITestTranscriptionFactory(),
                    repository: MeetingRepositoryLifecycleAdapter(
                        repository: repository
                    ),
                    panel: panel,
                    clock: UITestClock()
                )
            },
            modelPreparer: UITestModelPreparer(),
            credentialStore: credentials,
            settingsStore: settings,
            deepSeekTester: UITestDeepSeekTester(),
            notionTester: UITestNotionTester(),
            summaryGenerator: UITestSummaryGenerator(),
            notionArchiver: UITestNotionArchiver(repository: repository),
            notionTitleUpdater: NoopMeetingNotionTitleUpdater(),
            onboardingState: onboarding,
            systemRequirements: UITestSystemRequirements()
        )
    }
}

private struct UITestSystemRequirements: SystemRequirementChecking {
    func snapshot(for storageURL: URL) -> SystemRequirementsSnapshot {
        _ = storageURL
        return SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: 10 * 1_024 * 1_024 * 1_024
        )
    }
}

private struct UITestPermissionAuthorizer: MeetingPermissionAuthorizing {
    func requestRequiredPermissions(
        for mode: MeetingMode
    ) async -> [CapturePermission: CapturePermissionStatus] {
        Dictionary(
            uniqueKeysWithValues: CapturePermissionClient
                .requiredPermissions(for: mode)
                .map { ($0, .authorized) }
        )
    }
}

private struct UITestCaptureFactory: MeetingCaptureSourceFactory {
    func makeCapture(
        for mode: MeetingMode
    ) async throws -> any AudioCaptureSource {
        _ = mode
        return UITestCaptureSource()
    }
}

private actor UITestCaptureSource: AudioCaptureSource {
    private var continuation:
        AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        let pair = AsyncThrowingStream<CapturedAudioFrame, Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: AudioSegmentManifest.transcriptionSampleRate,
                samples: [0.1, -0.1, 0.05, -0.05]
            )
        )
        return pair.stream
    }

    func pause() async throws {}
    func resume() async throws {}

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private struct UITestWriterFactory: MeetingAudioWriterFactory {
    func makeWriter(
        meetingID: UUID
    ) async throws -> any MeetingAudioWriting {
        _ = meetingID
        return UITestWriter()
    }
}

private actor UITestWriter: MeetingAudioWriting {
    func append(_ frame: CapturedAudioFrame) async throws {
        _ = frame
    }

    func finish() async throws -> AudioSegmentManifest {
        AudioSegmentManifest()
    }
}

private struct UITestTranscriptionFactory: MeetingTranscriptionQueueFactory {
    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        UITestTranscriptionQueue()
    }
}

private actor UITestTranscriptionQueue: MeetingTranscriptionQueueing {
    private var drafts: [TranscriptDraft] = []
    private var continuation: AsyncStream<TranscriptDraft>.Continuation?

    func enqueue(samples: [Float], startingAt: TimeInterval) async {
        guard !samples.isEmpty else { return }
        let draft = TranscriptDraft(
            startTime: startingAt,
            endTime: startingAt + 1,
            text: "UI 测试会议转录"
        )
        drafts.append(draft)
        continuation?.yield(draft)
    }

    func drain() async {}
    func transcripts() async -> [TranscriptDraft] { drafts }

    func updates() async -> AsyncStream<TranscriptDraft> {
        let pair = AsyncStream<TranscriptDraft>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func finishUpdates() async {
        continuation?.finish()
        continuation = nil
    }
}

private actor UITestClock: MeetingClock {
    private var monotonicTime: TimeInterval = 100

    func now() async -> Date {
        Date(timeIntervalSince1970: 1_000 + monotonicTime)
    }

    func monotonicNow() async -> TimeInterval {
        defer { monotonicTime += 1 }
        return monotonicTime
    }
}

private actor UITestModelPreparer: TranscriptionModelPreparing {
    func prepare() async throws {}
}

private struct UITestDeepSeekTester: DeepSeekConnectionTesting {
    func testConnection(apiKey: String) async throws -> [String] {
        _ = apiKey
        return ["deepseek-chat", "deepseek-reasoner"]
    }
}

private struct UITestNotionTester: NotionConnectionTesting {
    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        _ = token
        return NotionConnectionResult(
            userID: "ui-test-user",
            userName: "UI Test",
            parentPage: NotionPageReference(
                id: parentPageID.uuidString,
                url: "https://www.notion.so/ui-test-parent"
            ),
            parentPageTitle: "UI 测试父页面"
        )
    }
}

private struct UITestSummaryGenerator: MeetingSummaryGenerating {
    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        _ = apiKey
        _ = input
        _ = model
        try await Task.sleep(for: .milliseconds(1_500))
        return GeneratedMeetingSummary(
            suggestedTitle: "UI 测试会议",
            overview: "端到端总结已完成。",
            keyPoints: ["录音与转录完成"],
            decisions: ["归档到 Notion"],
            actionItems: [
                ActionItem(
                    task: "检查会议记录",
                    owner: "测试人员",
                    dueDate: "今天"
                )
            ],
            bookmarkInsights: ["已记录关键节点"]
        )
    }
}

@MainActor
private final class UITestNotionArchiver: MeetingNotionArchiving {
    private let repository: MeetingRepository

    init(repository: MeetingRepository) {
        self.repository = repository
    }

    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference {
        _ = token
        _ = parentPageID
        _ = content
        try await Task.sleep(for: .milliseconds(1_500))
        let page = NotionPageReference(
            id: "ui-test-page",
            url: "https://www.notion.so/ui-test-page"
        )
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: page.id,
            pageURL: page.url
        )
        return page
    }
}
#endif
