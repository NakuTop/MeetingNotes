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
    func cancel() async
    func drain() async
    func transcripts() async -> [TranscriptDraft]
    func updates() async -> AsyncStream<TranscriptDraft>
    func finishUpdates() async
    func fixedTranscriptionService() async -> (any TranscriptionService)?
}

extension MeetingTranscriptionQueueing {
    func fixedTranscriptionService() async -> (any TranscriptionService)? {
        nil
    }
}

protocol MeetingTranscriptionQueueFactory: Sendable {
    func makeQueue() async throws -> any MeetingTranscriptionQueueing
}

protocol SpeakerDiarizationPreferenceReading: Sendable {
    func isSpeakerDiarizationEnabled() async -> Bool
}

protocol TranscriptionQualityPreferenceReading: Sendable {
    func transcriptionQualityMode() async -> TranscriptionQualityMode
}

protocol AudioInputDevicePreferenceReading: Sendable {
    func preferredInputDeviceID() async -> String?
}

protocol AudioOutputDevicePreferenceReading: Sendable {
    func preferredOutputDeviceID() async -> String?
}

struct SystemDefaultAudioOutputDevicePreference:
    AudioOutputDevicePreferenceReading {
    func preferredOutputDeviceID() async -> String? {
        nil
    }
}

@MainActor
final class MainActorAudioInputDevicePreferenceAdapter:
    AudioInputDevicePreferenceReading {
    private let settingsStore: AppSettingsStore
    private let deviceCatalog: (any AudioDeviceDiscovering)?

    init(
        settingsStore: AppSettingsStore,
        deviceCatalog: (any AudioDeviceDiscovering)? = nil
    ) {
        self.settingsStore = settingsStore
        self.deviceCatalog = deviceCatalog
    }

    func preferredInputDeviceID() async -> String? {
        let preferredID = settingsStore.preferredInputDeviceID
        guard let deviceCatalog else {
            return preferredID
        }
        guard let snapshot = try? await deviceCatalog.snapshot() else {
            return preferredID
        }
        switch AudioDevicePreferenceResolver.resolveInput(
            preferredID: preferredID,
            devices: snapshot.inputs
        ) {
        case let .preferred(device),
             let .firstUsable(device):
            return device.id
        case .systemDefault:
            return nil
        case let .fallback(selected, _):
            return selected.id
        case .unavailable:
            return preferredID
        }
    }
}

@MainActor
final class MainActorAudioOutputDevicePreferenceAdapter:
    AudioOutputDevicePreferenceReading {
    private let settingsStore: AppSettingsStore
    private let deviceCatalog: (any AudioDeviceDiscovering)?

    init(
        settingsStore: AppSettingsStore,
        deviceCatalog: (any AudioDeviceDiscovering)? = nil
    ) {
        self.settingsStore = settingsStore
        self.deviceCatalog = deviceCatalog
    }

    func preferredOutputDeviceID() async -> String? {
        let preferredID = settingsStore.preferredOutputDeviceID
        guard let deviceCatalog else {
            return preferredID
        }
        guard let snapshot = try? await deviceCatalog.snapshot() else {
            return preferredID
        }
        switch AudioDevicePreferenceResolver.resolveOutput(
            preferredID: preferredID,
            devices: snapshot.outputs
        ) {
        case let .preferred(device),
             let .firstUsable(device):
            return device.id
        case .systemDefault:
            return nil
        case let .fallback(selected, _):
            return selected.id
        case .unavailable:
            return preferredID
        }
    }
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

@MainActor
final class MainActorTranscriptionQualityPreferenceAdapter:
    TranscriptionQualityPreferenceReading {
    private let settingsStore: AppSettingsStore

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    func transcriptionQualityMode() async -> TranscriptionQualityMode {
        settingsStore.transcriptionQualityMode
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
    func markSpeakerProcessingStarted(meetingID: UUID) async throws
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
    func finalizeInterruptedMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        lastErrorCode: String
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

protocol MeetingCaptureInterruptionReporting: Sendable {
    func captureInterrupted(meetingID: UUID) async
}

struct NoopMeetingCaptureInterruptionReporter:
    MeetingCaptureInterruptionReporting {
    func captureInterrupted(meetingID: UUID) async {
        _ = meetingID
    }
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
    let captureHealthScheduler: any CaptureHealthCheckScheduling
    let recordingPresentation:
        any RecordingSessionPresentationUpdating
    let captureInterruptionReporter:
        any MeetingCaptureInterruptionReporting

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
        clock: any MeetingClock,
        captureHealthScheduler: any CaptureHealthCheckScheduling =
            ContinuousCaptureHealthCheckScheduler(),
        recordingPresentation:
            any RecordingSessionPresentationUpdating =
            NoopRecordingSessionPresentationUpdater(),
        captureInterruptionReporter:
            any MeetingCaptureInterruptionReporting =
            NoopMeetingCaptureInterruptionReporter()
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
        self.captureHealthScheduler = captureHealthScheduler
        self.recordingPresentation = recordingPresentation
        self.captureInterruptionReporter = captureInterruptionReporter
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
    typealias MicrophoneFactory =
        @Sendable (String?) -> any AudioCaptureSource
    typealias ScreenFactory =
        @Sendable (String?) -> any AudioCaptureSource

    private let audioInputDevicePreference:
        any AudioInputDevicePreferenceReading
    private let microphoneFactory: MicrophoneFactory
    private let screenFactory: ScreenFactory

    init(
        audioInputDevicePreference:
            any AudioInputDevicePreferenceReading,
        microphoneFactory:
            @escaping MicrophoneFactory = { selectedDeviceID in
                MicrophoneCaptureSource(
                    selectedDeviceID: selectedDeviceID
                )
            },
        screenFactory:
            @escaping ScreenFactory = { selectedDeviceID in
                ScreenAudioCaptureSource(
                    microphoneDeviceID: selectedDeviceID
                )
            }
    ) {
        self.audioInputDevicePreference = audioInputDevicePreference
        self.microphoneFactory = microphoneFactory
        self.screenFactory = screenFactory
    }

    func makeCapture(for mode: MeetingMode) async throws -> any AudioCaptureSource {
        switch mode {
        case .offline:
            let selectedDeviceID =
                await audioInputDevicePreference
                    .preferredInputDeviceID()
            return microphoneFactory(selectedDeviceID)
        case .online:
            let selectedDeviceID =
                await audioInputDevicePreference
                    .preferredInputDeviceID()
            return screenFactory(selectedDeviceID)
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
    let modelController: any TranscriptionModelControlling
    let qualityPreference: any TranscriptionQualityPreferenceReading

    init(
        modelController: any TranscriptionModelControlling,
        qualityPreference: any TranscriptionQualityPreferenceReading
    ) {
        self.modelController = modelController
        self.qualityPreference = qualityPreference
    }

    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        let mode = await qualityPreference.transcriptionQualityMode()
        let service = try await modelController.service(mode: mode)
        return LiveMeetingTranscriptionQueue(
            queue: TranscriptionQueue(
                service: service
            ),
            service: service
        )
    }
}

private actor LiveMeetingTranscriptionQueue: MeetingTranscriptionQueueing {
    private let queue: TranscriptionQueue
    private let service: any TranscriptionService

    init(
        queue: TranscriptionQueue,
        service: any TranscriptionService
    ) {
        self.queue = queue
        self.service = service
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) async {
        await queue.enqueue(samples: samples, startingAt: startingAt)
    }

    func cancel() async {
        await queue.cancel()
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

    func fixedTranscriptionService() -> (any TranscriptionService)? {
        service
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

    func markSpeakerProcessingStarted(meetingID: UUID) async throws {
        try repository.markSpeakerProcessingStarted(meetingID: meetingID)
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

    func finalizeInterruptedMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        lastErrorCode: String
    ) async throws {
        try repository.finalizeInterruptedMeeting(
            id: meetingID,
            endedAt: endedAt,
            activeDuration: activeDuration,
            lastErrorCode: lastErrorCode
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
        audioInputDevicePreference:
            any AudioInputDevicePreferenceReading,
        permissionSystem: any CapturePermissionSystem = LiveCapturePermissionSystem(),
        panel: any RecordingPanelPresenting = NoopRecordingPanelPresenter(),
        recordingPresentation:
            any RecordingSessionPresentationUpdating =
            NoopRecordingSessionPresentationUpdater(),
        captureInterruptionReporter:
            any MeetingCaptureInterruptionReporting =
            NoopMeetingCaptureInterruptionReporter(),
        sourceLoader: MeetingAudioSourceLoader? = nil,
        transcriptionModelController: any TranscriptionModelControlling,
        transcriptionQualityPreference:
            any TranscriptionQualityPreferenceReading,
        speakerDiarizer: any SpeakerDiarizing
    ) -> MeetingCoordinatorDependencies {
        let sourceLoader = sourceLoader
            ?? MeetingAudioSourceLoader(fileStore: fileStore)
        return MeetingCoordinatorDependencies(
            permissions: CapturePermissionClient(system: permissionSystem),
            captureFactory: LiveMeetingCaptureFactory(
                audioInputDevicePreference:
                    audioInputDevicePreference
            ),
            writerFactory: LiveMeetingAudioWriterFactory(fileStore: fileStore),
            transcriptionFactory: LiveMeetingTranscriptionQueueFactory(
                modelController: transcriptionModelController,
                qualityPreference: transcriptionQualityPreference
            ),
            repository: MeetingRepositoryLifecycleAdapter(repository: repository),
            speakerDiarizationPreference: speakerDiarizationPreference,
            speakerFinalizer: SpeakerAwareTranscriptFinalizer(
                reader: MeetingTrackAudioReader(
                    sourceLoader: sourceLoader
                ),
                sourceLoader: sourceLoader,
                diarizer: speakerDiarizer
            ),
            panel: panel,
            clock: SystemMeetingClock(),
            recordingPresentation: recordingPresentation,
            captureInterruptionReporter: captureInterruptionReporter
        )
    }
}
