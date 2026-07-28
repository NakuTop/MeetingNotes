import Foundation

protocol MeetingPermissionAuthorizing: Sendable {
    func requestRequiredPermissions(
        for mode: MeetingMode
    ) async -> [CapturePermission: CapturePermissionStatus]
}

extension CapturePermissionClient: MeetingPermissionAuthorizing {}

protocol MeetingCaptureSourceFactory: Sendable {
    func makeCapture(for mode: MeetingMode) async throws -> any AudioCaptureSource
}

protocol MeetingAudioWriting: Sendable {
    func append(_ frame: CapturedAudioFrame) async throws
    func finish() async throws -> AudioSegmentManifest
}

extension SegmentedPCMWriter: MeetingAudioWriting {}

protocol MeetingAudioWriterFactory: Sendable {
    func makeWriter(
        meetingID: UUID,
        track: AudioTrack,
        sampleRate: Double
    ) async throws -> any MeetingAudioWriting
}

protocol MeetingTranscriptionQueueing: Sendable {
    func enqueue(samples: [Float], startingAt: TimeInterval) async
    func drain() async
    func transcripts() async -> [TranscriptDraft]
    func updates() async -> AsyncStream<TranscriptDraft>
    func finishUpdates() async
}

protocol MeetingTranscriptionQueueFactory: Sendable {
    func makeQueue() async throws -> any MeetingTranscriptionQueueing
}

protocol SpeakerDiarizationPreferenceReading: Sendable {
    func isSpeakerDiarizationEnabled() async -> Bool
}

@MainActor
final class MainActorSpeakerDiarizationPreferenceAdapter:
    SpeakerDiarizationPreferenceReading {
    private let settingsStore: AppSettingsStore

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    func isSpeakerDiarizationEnabled() async -> Bool {
        settingsStore.isSpeakerDiarizationEnabled
    }
}

protocol MeetingLifecycleRepository: Sendable {
    func createMeeting(
        mode: MeetingMode,
        startedAt: Date,
        speakerDiarizationRequested: Bool
    ) async throws -> UUID
    func updateState(meetingID: UUID, state: RecordingState) async throws
    func appendBookmark(meetingID: UUID, timestamp: TimeInterval) async throws
    func appendTranscript(meetingID: UUID, draft: TranscriptDraft) async throws
    func replaceTranscripts(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int
    ) async throws
    func markSpeakerProcessingDegraded(
        meetingID: UUID,
        errorCode: String
    ) async throws
    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        sourceDegradationErrorCode: String?
    ) async throws
    func deleteMeeting(meetingID: UUID) async throws
}

protocol RecordingPanelPresenting: Sendable {
    func show() async
    func hide() async
}

protocol MeetingClock: Sendable {
    func now() async -> Date
    func monotonicNow() async -> TimeInterval
}

struct MeetingCoordinatorDependencies: Sendable {
    let permissions: any MeetingPermissionAuthorizing
    let captureFactory: any MeetingCaptureSourceFactory
    let writerFactory: any MeetingAudioWriterFactory
    let transcriptionFactory: any MeetingTranscriptionQueueFactory
    let repository: any MeetingLifecycleRepository
    let speakerDiarizationPreference:
        any SpeakerDiarizationPreferenceReading
    let speakerFinalizer: any MeetingSpeakerFinalizing
    let panel: any RecordingPanelPresenting
    let clock: any MeetingClock

    init(
        permissions: any MeetingPermissionAuthorizing,
        captureFactory: any MeetingCaptureSourceFactory,
        writerFactory: any MeetingAudioWriterFactory,
        transcriptionFactory: any MeetingTranscriptionQueueFactory,
        repository: any MeetingLifecycleRepository,
        speakerDiarizationPreference:
            any SpeakerDiarizationPreferenceReading,
        speakerFinalizer: any MeetingSpeakerFinalizing =
            UnchangedMeetingSpeakerFinalizer(),
        panel: any RecordingPanelPresenting,
        clock: any MeetingClock
    ) {
        self.permissions = permissions
        self.captureFactory = captureFactory
        self.writerFactory = writerFactory
        self.transcriptionFactory = transcriptionFactory
        self.repository = repository
        self.speakerDiarizationPreference = speakerDiarizationPreference
        self.speakerFinalizer = speakerFinalizer
        self.panel = panel
        self.clock = clock
    }
}

private struct UnchangedMeetingSpeakerFinalizer:
    MeetingSpeakerFinalizing {
    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        _ = meetingID
        _ = mode
        _ = diarizationRequested
        _ = provisional
        return .unchanged
    }
}

struct LiveMeetingCaptureFactory: MeetingCaptureSourceFactory {
    func makeCapture(for mode: MeetingMode) async throws -> any AudioCaptureSource {
        switch mode {
        case .offline:
            return MicrophoneCaptureSource()
        case .online:
            return ScreenAudioCaptureSource()
        }
    }
}

struct LiveMeetingAudioWriterFactory: MeetingAudioWriterFactory {
    let fileStore: MeetingFileStore

    func makeWriter(
        meetingID: UUID,
        track: AudioTrack,
        sampleRate: Double
    ) async throws -> any MeetingAudioWriting {
        try SegmentedPCMWriter(
            meetingID: meetingID,
            fileStore: fileStore,
            track: track,
            sampleRate: sampleRate
        )
    }
}

struct LiveMeetingTranscriptionQueueFactory: MeetingTranscriptionQueueFactory {
    let service: any TranscriptionService

    init(service: any TranscriptionService = WhisperKitTranscriptionService(
        model: "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page")) {
        self.service = service
    }

    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        LiveMeetingTranscriptionQueue(
            queue: TranscriptionQueue(
                service: service
            )
        )
    }
}

private actor LiveMeetingTranscriptionQueue: MeetingTranscriptionQueueing {
    private let queue: TranscriptionQueue

    init(queue: TranscriptionQueue) {
        self.queue = queue
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) async {
        await queue.enqueue(samples: samples, startingAt: startingAt)
    }

    func drain() async {
        await queue.drain()
    }

    func transcripts() async -> [TranscriptDraft] {
        await queue.transcripts()
    }

    func updates() async -> AsyncStream<TranscriptDraft> {
        await queue.updates()
    }

    func finishUpdates() async {
        await queue.finishUpdates()
    }
}

@MainActor
final class MeetingRepositoryLifecycleAdapter: MeetingLifecycleRepository {
    private let repository: MeetingRepository

    init(repository: MeetingRepository) {
        self.repository = repository
    }

    func createMeeting(
        mode: MeetingMode,
        startedAt: Date,
        speakerDiarizationRequested: Bool
    ) async throws -> UUID {
        try repository.createMeeting(
            mode: mode,
            startedAt: startedAt,
            speakerDiarizationRequested: speakerDiarizationRequested
        )
    }

    func updateState(meetingID: UUID, state: RecordingState) async throws {
        try repository.updateMeetingState(id: meetingID, state: state)
    }

    func appendBookmark(
        meetingID: UUID,
        timestamp: TimeInterval
    ) async throws {
        try repository.appendBookmark(
            meetingID: meetingID,
            timestamp: timestamp
        )
    }

    func appendTranscript(
        meetingID: UUID,
        draft: TranscriptDraft
    ) async throws {
        try repository.appendTranscript(
            meetingID: meetingID,
            start: draft.startTime,
            end: draft.endTime,
            text: draft.text
        )
    }

    func replaceTranscripts(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int
    ) async throws {
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: drafts,
            sourceRevision: sourceRevision
        )
    }

    func markSpeakerProcessingDegraded(
        meetingID: UUID,
        errorCode: String
    ) async throws {
        let meeting = try repository.meeting(id: meetingID)
        let previousStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode = errorCode
        do {
            try repository.updateMeetingState(
                id: meetingID,
                state: meeting.state
            )
        } catch {
            meeting.speakerProcessingStateRawValue =
                previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        sourceDegradationErrorCode: String?
    ) async throws {
        try repository.finalizeMeeting(
            id: meetingID,
            endedAt: endedAt,
            activeDuration: activeDuration,
            sourceDegradationErrorCode: sourceDegradationErrorCode
        )
    }

    func deleteMeeting(meetingID: UUID) async throws {
        try repository.deleteMeeting(id: meetingID)
    }
}

struct NoopRecordingPanelPresenter: RecordingPanelPresenting {
    func show() async {}
    func hide() async {}
}

struct SystemMeetingClock: MeetingClock {
    func now() async -> Date {
        .now
    }

    func monotonicNow() async -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

extension MeetingCoordinatorDependencies {
    @MainActor
    static func live(
        repository: MeetingRepository,
        fileStore: MeetingFileStore,
        speakerDiarizationPreference:
            any SpeakerDiarizationPreferenceReading,
        permissionSystem: any CapturePermissionSystem = LiveCapturePermissionSystem(),
        panel: any RecordingPanelPresenting = NoopRecordingPanelPresenter(),
        sourceLoader: MeetingAudioSourceLoader? = nil,
        transcriptionService: any TranscriptionService =
            WhisperKitTranscriptionService(
                model: "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"),
        speakerDiarizer: any SpeakerDiarizing
    ) -> MeetingCoordinatorDependencies {
        let sourceLoader = sourceLoader
            ?? MeetingAudioSourceLoader(fileStore: fileStore)
        return MeetingCoordinatorDependencies(
            permissions: CapturePermissionClient(system: permissionSystem),
            captureFactory: LiveMeetingCaptureFactory(),
            writerFactory: LiveMeetingAudioWriterFactory(fileStore: fileStore),
            transcriptionFactory: LiveMeetingTranscriptionQueueFactory(
                service: transcriptionService
            ),
            repository: MeetingRepositoryLifecycleAdapter(repository: repository),
            speakerDiarizationPreference: speakerDiarizationPreference,
            speakerFinalizer: SpeakerAwareTranscriptFinalizer(
                reader: MeetingTrackAudioReader(
                    sourceLoader: sourceLoader
                ),
                transcriptionService: transcriptionService,
                sourceLoader: sourceLoader,
                diarizer: speakerDiarizer
            ),
            panel: panel,
            clock: SystemMeetingClock()
        )
    }
}
