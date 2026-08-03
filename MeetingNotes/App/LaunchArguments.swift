import Foundation

enum LaunchArguments {
    static let uiTesting = "-uiTesting"
    static let uiTestingSlowRenameEnvironment =
        "MEETING_NOTES_UI_SLOW_RENAME"
    static let uiTestingAudioPlayerEnvironment =
        "MEETING_NOTES_UI_AUDIO_PLAYER"
    static let uiTestingAudioPlayerMeetingIDEnvironment =
        "MEETING_NOTES_UI_AUDIO_PLAYER_MEETING_ID"
    static let uiTestingAudioPlayerLifecycleTriggerEnvironment =
        "MEETING_NOTES_UI_AUDIO_PLAYER_LIFECYCLE_TRIGGER"
    static let uiTestingDocumentsEnvironment =
        "MEETING_NOTES_UI_DOCUMENTS"
    static let uiTestingSpeakerArchiveEnvironment =
        "MEETING_NOTES_UI_SPEAKER_ARCHIVE"

    static func isUITesting(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(uiTesting)
    }

    static func usesSlowRenameUITestFixture(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[uiTestingSlowRenameEnvironment] == "1"
    }

    static func usesAudioPlayerUITestFixture(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[uiTestingAudioPlayerEnvironment] == "1"
    }

    static func usesDocumentsUITestFixture(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[uiTestingDocumentsEnvironment] == "1"
    }

    static func usesSpeakerArchiveUITestFixture(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[uiTestingSpeakerArchiveEnvironment] == "1"
    }

    static func audioPlayerLifecycleTriggerURL(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[
            uiTestingAudioPlayerLifecycleTriggerEnvironment
        ], !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == "/tmp",
              url.lastPathComponent.hasPrefix(
                "MeetingNotes-UITesting-Trigger-"
              ),
              url.pathExtension.isEmpty else {
            return nil
        }
        return url
    }

    static func audioPlayerMeetingID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UUID? {
        guard let value = environment[
            uiTestingAudioPlayerMeetingIDEnvironment
        ] else {
            return nil
        }
        return UUID(uuidString: value)
    }
}

#if DEBUG
@MainActor
extension AppContainer {
    static func uiTesting(
        speakerDiarizationEnabled: Bool = false
    ) throws -> AppContainer {
        let repository = try MeetingRepository.inMemory()
        let usesSlowRenameFixture =
            LaunchArguments.usesSlowRenameUITestFixture()
        let usesAudioPlayerFixture =
            LaunchArguments.usesAudioPlayerUITestFixture()
        let usesDocumentsFixture =
            LaunchArguments.usesDocumentsUITestFixture()
        let usesSpeakerArchiveFixture =
            LaunchArguments.usesSpeakerArchiveUITestFixture()
        let audioPlayerMeetingID = LaunchArguments.audioPlayerMeetingID()
        let audioPlayerLifecycleTriggerURL =
            LaunchArguments.audioPlayerLifecycleTriggerURL()
        let recordingsURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "MeetingNotes-UITesting-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        if usesSlowRenameFixture {
            let startedAt = Date(timeIntervalSince1970: 1_000)
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: startedAt,
                title: "慢速归档会议"
            )
            try repository.finalizeMeeting(
                id: meetingID,
                endedAt: startedAt.addingTimeInterval(60),
                activeDuration: 60
            )
            try repository.setNotionPage(
                meetingID: meetingID,
                pageID: "ui-test-slow-rename-page",
                pageURL: "https://www.notion.so/ui-test-slow-rename-page"
            )
            try repository.updateMeetingState(id: meetingID, state: .archived)
        }
        if usesAudioPlayerFixture, let audioPlayerMeetingID {
            let startedAt = Date(timeIntervalSince1970: 2_000)
            _ = try repository.createMeeting(
                id: audioPlayerMeetingID,
                mode: .offline,
                startedAt: startedAt,
                title: "可播放录音会议"
            )
            try repository.finalizeMeeting(
                id: audioPlayerMeetingID,
                endedAt: startedAt.addingTimeInterval(8),
                activeDuration: 8
            )
        }
        if audioPlayerLifecycleTriggerURL != nil,
           let audioPlayerMeetingID {
            let startedAt = Date(timeIntervalSince1970: 3_000)
            _ = try repository.createMeeting(
                id: audioPlayerMeetingID,
                mode: .offline,
                startedAt: startedAt,
                title: "录音即将完成会议"
            )
        }
        if usesDocumentsFixture {
            let startedAt = Date(timeIntervalSince1970: 4_000)
            let meetingID = try repository.createMeeting(
                mode: .online,
                startedAt: startedAt,
                title: "双模式会议文档"
            )
            try repository.finalizeMeeting(
                id: meetingID,
                endedAt: startedAt.addingTimeInterval(600),
                activeDuration: 600
            )
            try repository.appendTranscript(
                meetingID: meetingID,
                start: 0,
                end: 8,
                text: "我和远端讨论了发布安排。",
                isFinal: true,
                speakerID: "me"
            )
            try repository.saveGeneratedSummary(
                meetingID: meetingID,
                generated: GeneratedMeetingSummary(
                    suggestedTitle: "双模式会议文档",
                    overview: "UI 双模式重点总结",
                    keyPoints: ["确认发布范围"],
                    decisions: ["本周发布"],
                    actionItems: [
                        ActionItem(task: "准备发布", owner: "我", dueDate: "周五")
                    ],
                    bookmarkInsights: []
                ),
                model: "ui-test-model"
            )
            try repository.saveGeneratedDetailedMinutes(
                meetingID: meetingID,
                generated: GeneratedDetailedMinutes(
                    overview: "UI 双模式完整纪要",
                    sections: [
                        DetailedMinutesSection(
                            title: "发布讨论",
                            timeRange: "00:00–00:08",
                            speakers: ["我", "远端 1"],
                            content: "双方确认了发布范围和时间。"
                        )
                    ],
                    decisions: ["本周发布"],
                    actionItems: [
                        ActionItem(task: "准备发布", owner: "我", dueDate: "周五")
                    ],
                    openQuestions: ["回滚窗口待确认"]
                ),
                model: "ui-test-model",
                promptVersion: 1
            )
        }
        if usesSpeakerArchiveFixture {
            let startedAt = Date(timeIntervalSince1970: 5_000)
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: startedAt,
                title: "说话人标签会议"
            )
            try repository.finalizeMeeting(
                id: meetingID,
                endedAt: startedAt.addingTimeInterval(30),
                activeDuration: 30
            )
            let transcriptDrafts = [
                (0.0, 2.0, "先确认议题。", "room-1"),
                (2.5, 4.0, "再确认时间。", "room-1"),
                (5.0, 6.0, "我来补充安排。", "room-2"),
                (12.0, 13.0, "议题已经确认。", "room-1"),
                (20.0, 21.0, "安排也已确认。", "room-2")
            ].map { transcript in
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: transcript.0,
                        endTime: transcript.1,
                        text: transcript.2
                    ),
                    speakerID: transcript.3,
                    source: .room
                )
            }
            try repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: transcriptDrafts,
                sourceRevision: 1
            )
            try repository.setSpeakerDisplayName(
                meetingID: meetingID,
                speakerID: "room-1",
                displayName: "项目经理"
            )
            let partialMeetingID = try repository.createMeeting(
                mode: .online,
                startedAt: startedAt.addingTimeInterval(100),
                title: "部分归档会议"
            )
            try repository.finalizeMeeting(
                id: partialMeetingID,
                endedAt: startedAt.addingTimeInterval(130),
                activeDuration: 30
            )
            try repository.saveGeneratedSummary(
                meetingID: partialMeetingID,
                generated: GeneratedMeetingSummary(
                    suggestedTitle: "部分归档会议",
                    overview: "用于 UI 验收的重点总结。",
                    keyPoints: ["确认议题和安排"],
                    decisions: ["按计划推进"],
                    actionItems: [],
                    bookmarkInsights: []
                ),
                model: "ui-test-model"
            )
            try repository.saveGeneratedDetailedMinutes(
                meetingID: partialMeetingID,
                generated: GeneratedDetailedMinutes(
                    overview: "用于 UI 验收的完整纪要。",
                    sections: [
                        DetailedMinutesSection(
                            title: "议题确认",
                            timeRange: "00:00–00:21",
                            speakers: ["项目经理", "说话人 2"],
                            content: "参会者确认了议题和安排。"
                        )
                    ],
                    decisions: ["按计划推进"],
                    actionItems: [],
                    openQuestions: []
                ),
                model: "ui-test-model",
                promptVersion: 1
            )
            try repository.completeDocumentArchive(
                meetingID: partialMeetingID,
                kind: .detailedMinutes
            )
            try repository.setNotionPage(
                meetingID: partialMeetingID,
                pageID: "ui-test-partial-archive-page",
                pageURL: "https://www.notion.so/ui-test-partial-archive-page"
            )
        }
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
        settings.isSpeakerDiarizationEnabled = speakerDiarizationEnabled
        settings.notionParentPageURL =
            "https://www.notion.so/UI-Parent-1234567890abcdef1234567890abcdef"
        if usesSpeakerArchiveFixture {
            settings.frequentSpeakerNames = ["张三", "李四"]
        }
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.completePrivacyAndConsent()

        let container = AppContainer(
            repository: repository,
            fileStore: fileStore,
            recordingsURL: recordingsURL,
            coordinatorDependencies: {
                panel,
                speakerPreference,
                recordingPresentation in
                MeetingCoordinatorDependencies(
                    permissions: UITestPermissionAuthorizer(),
                    captureFactory: UITestCaptureFactory(),
                    writerFactory: UITestWriterFactory(),
                    transcriptionFactory: UITestTranscriptionFactory(),
                    repository: MeetingRepositoryLifecycleAdapter(
                        repository: repository
                    ),
                    speakerDiarizationPreference: speakerPreference,
                    panel: panel,
                    clock: UITestClock(),
                    recordingPresentation: recordingPresentation
                )
            },
            modelPreparer: UITestModelPreparer(),
            credentialStore: credentials,
            settingsStore: settings,
            deepSeekTester: UITestDeepSeekTester(),
            notionTester: UITestNotionTester(),
            summaryGenerator: UITestSummaryGenerator(),
            detailedMinutesGenerator: UITestDetailedMinutesGenerator(),
            notionArchiver: UITestNotionArchiver(repository: repository),
            notionTitleUpdater: usesSlowRenameFixture
                ? UITestDelayedNotionTitleUpdater()
                : NoopMeetingNotionTitleUpdater(),
            onboardingState: onboarding,
            systemRequirements: UITestSystemRequirements(),
            audioDeviceCatalog: UITestAudioDeviceCatalog(),
            audioInputTester: UITestAudioInputTester(),
            audioOutputTester: UITestAudioOutputTester(),
            audioDiagnosticCoordinatorFactory:
                UITestAudioDiagnosticCoordinatorFactory(),
            audioDiagnosticExplainer: UITestAudioDiagnosticExplainer()
        )
        if let triggerURL = audioPlayerLifecycleTriggerURL,
           let meetingID = audioPlayerMeetingID {
            monitorAudioPlayerLifecycleFixture(
                triggerURL: triggerURL,
                meetingID: meetingID,
                container: container
            )
        }
        return container
    }

    private static func monitorAudioPlayerLifecycleFixture(
        triggerURL: URL,
        meetingID: UUID,
        container: AppContainer
    ) {
        Task { @MainActor [weak container] in
            while !Task.isCancelled {
                guard let container else { return }
                if FileManager.default.fileExists(atPath: triggerURL.path) {
                    let endedAt = Date(timeIntervalSince1970: 3_008)
                    try? container.repository.finalizeMeeting(
                        id: meetingID,
                        endedAt: endedAt,
                        activeDuration: 8
                    )
                    container.libraryViewModel.load()
                    container.detailViewModel(for: meetingID).load()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }
}

@MainActor
private final class UITestDelayedNotionTitleUpdater:
    MeetingNotionTitleUpdating {
    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        _ = token
        _ = pageID
        _ = title
        try await Task.sleep(for: .seconds(5))
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
        AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        let pair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(
            CapturedAudioPacket(
                master: CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: AudioSegmentManifest.transcriptionSampleRate,
                    samples: Array(
                        repeating: 0.1,
                        count: MeetingCoordinator
                            .productionTranscriptionChunkSampleCount
                    )
                ),
                sourceFrames: [:]
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
        meetingID: UUID,
        track: AudioTrack,
        sampleRate: Double
    ) async throws -> any MeetingAudioWriting {
        _ = meetingID
        _ = track
        _ = sampleRate
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

    func cancel() async {
        drafts.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil
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
    func now() async -> Date {
        .now
    }

    func monotonicNow() async -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
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

private struct UITestAudioDeviceCatalog: AudioDeviceDiscovering {
    func snapshot() async throws -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            inputs: [
                AudioInputDevice(
                    id: "ui-built-in-microphone",
                    name: "UI 测试麦克风",
                    manufacturer: "MeetingNotes",
                    isConnected: true,
                    isSuspended: false,
                    isInUseByAnotherApplication: false,
                    isSystemDefault: true
                )
            ],
            outputs: [
                AudioOutputDevice(
                    id: "ui-built-in-output",
                    name: "UI 测试扬声器",
                    isConnected: true,
                    isSystemDefault: true
                )
            ]
        )
    }
}

private actor UITestAudioInputTester: AudioDiagnosticSignalTesting {
    private var continuation:
        CheckedContinuation<AudioSignalMetrics, Error>?

    func testSignal(duration: TimeInterval) async throws
        -> AudioSignalMetrics {
        try await testSignal(duration: duration) { _ in }
    }

    func testSignal(
        duration: TimeInterval,
        onMetrics: @escaping @Sendable (AudioSignalMetrics) async -> Void
    ) async throws -> AudioSignalMetrics {
        _ = duration
        let metrics = uiTestAudioMetrics()
        await onMetrics(metrics)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private struct UITestAudioOutputTester: AudioOutputTesting {
    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        AudioOutputTestResult(
            wasScheduled: true,
            duration: duration,
            outputDeviceID: nil
        )
    }

    func stop() async {}
}

private struct UITestAudioDiagnosticCoordinatorFactory:
    AudioDiagnosticCoordinatorCreating {
    func makeCoordinator() async -> any AudioDiagnosticCoordinating {
        UITestAudioDiagnosticCoordinator()
    }
}

private actor UITestAudioDiagnosticCoordinator:
    AudioDiagnosticCoordinating {
    private var state: AudioDiagnosticCoordinatorState = .idle

    func prepare() async throws {
        state = .awaitingOutputConfirmation
    }

    func continueAfterOutputConfirmation(
        heardTone: Bool
    ) async throws {
        state = .readyForUpload(
            AudioDiagnosticReport(
                primaryIssue: heardTone
                    ? .captureHealthy
                    : .outputNotAudible,
                supportingIssues: [],
                facts: AudioDiagnosticFacts(
                    microphonePermission: .authorized,
                    screenPermission: .authorized,
                    inputDeviceAvailable: true,
                    outputToneWasScheduled: true,
                    userHeardOutputTone: heardTone,
                    microphoneMetrics: uiTestAudioMetrics(),
                    systemAudioMetrics: uiTestAudioMetrics(),
                    historicalPlaybackFailed: false
                )
            )
        )
    }

    func cancel() async {
        state = .idle
    }

    func currentState() async -> AudioDiagnosticCoordinatorState {
        state
    }
}

private struct UITestAudioDiagnosticExplainer:
    AudioDiagnosticExplanationRequesting {
    func requestExplanation(
        apiKey: String,
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata,
        model: String
    ) async throws -> AudioDiagnosticExplanation {
        _ = apiKey
        _ = metadata
        _ = model
        return AudioDiagnosticExplanation(
            issue: report.localIssue,
            solution: report.localSolution,
            source: .deepSeek
        )
    }
}

private func uiTestAudioMetrics() -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 144_000,
        rms: 0.1,
        peak: 0.2,
        observationDuration: 3,
        sampleRate: 48_000,
        channelCount: 1,
        level: .audible
    )
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

private struct UITestDetailedMinutesGenerator:
    MeetingDetailedMinutesGenerating {
    func detailedMinutes(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedDetailedMinutes {
        _ = apiKey
        _ = input
        _ = model
        try await Task.sleep(for: .milliseconds(1_500))
        return GeneratedDetailedMinutes(
            overview: "UI 生成的完整纪要",
            sections: [
                DetailedMinutesSection(
                    title: "讨论",
                    timeRange: "00:00–00:08",
                    speakers: ["我", "远端 1"],
                    content: "已整理会议讨论。"
                )
            ],
            decisions: ["继续执行"],
            actionItems: [],
            openQuestions: []
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
