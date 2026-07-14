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
    func makeWriter(meetingID: UUID) async throws -> any MeetingAudioWriting
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

protocol MeetingLifecycleRepository: Sendable {
    func createMeeting(mode: MeetingMode, startedAt: Date) async throws -> UUID
    func updateState(meetingID: UUID, state: RecordingState) async throws
    func appendBookmark(meetingID: UUID, timestamp: TimeInterval) async throws
    func appendTranscript(meetingID: UUID, draft: TranscriptDraft) async throws
    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval
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
    let panel: any RecordingPanelPresenting
    let clock: any MeetingClock

    init(
        permissions: any MeetingPermissionAuthorizing,
        captureFactory: any MeetingCaptureSourceFactory,
        writerFactory: any MeetingAudioWriterFactory,
        transcriptionFactory: any MeetingTranscriptionQueueFactory,
        repository: any MeetingLifecycleRepository,
        panel: any RecordingPanelPresenting,
        clock: any MeetingClock
    ) {
        self.permissions = permissions
        self.captureFactory = captureFactory
        self.writerFactory = writerFactory
        self.transcriptionFactory = transcriptionFactory
        self.repository = repository
        self.panel = panel
        self.clock = clock
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

    func makeWriter(meetingID: UUID) async throws -> any MeetingAudioWriting {
        try SegmentedPCMWriter(meetingID: meetingID, fileStore: fileStore)
    }
}

struct LiveMeetingTranscriptionQueueFactory: MeetingTranscriptionQueueFactory {
    let model: String?

    init(model: String? = nil) {
        self.model = model
    }

    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        LiveMeetingTranscriptionQueue(
            queue: TranscriptionQueue(
                service: WhisperKitTranscriptionService(model: model)
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

    func createMeeting(mode: MeetingMode, startedAt: Date) async throws -> UUID {
        try repository.createMeeting(mode: mode, startedAt: startedAt)
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

    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval
    ) async throws {
        try repository.finalizeMeeting(
            id: meetingID,
            endedAt: endedAt,
            activeDuration: activeDuration
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
        permissionSystem: any CapturePermissionSystem = LiveCapturePermissionSystem(),
        panel: any RecordingPanelPresenting = NoopRecordingPanelPresenter(),
        whisperModel: String? = nil
    ) -> MeetingCoordinatorDependencies {
        MeetingCoordinatorDependencies(
            permissions: CapturePermissionClient(system: permissionSystem),
            captureFactory: LiveMeetingCaptureFactory(),
            writerFactory: LiveMeetingAudioWriterFactory(fileStore: fileStore),
            transcriptionFactory: LiveMeetingTranscriptionQueueFactory(
                model: whisperModel
            ),
            repository: MeetingRepositoryLifecycleAdapter(repository: repository),
            panel: panel,
            clock: SystemMeetingClock()
        )
    }
}
