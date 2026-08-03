import XCTest
import SwiftData
@testable import MeetingNotes

@MainActor
final class SpeakerDiarizationRetryUseCaseTests: XCTestCase {
    func testOfflineRetryUsesMasterAudioAndOnlyReattributesExistingFinalText()
        async throws {
        let repository = try makeRetryableMeeting(mode: .offline)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 2,
            text: "existing first",
            speakerID: "room-7",
            sourceRevision: 4
        )
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 2,
            end: 4,
            text: "existing second",
            speakerID: "room-8",
            sourceRevision: 4
        )
        try repository.meeting(id: meeting.id).transcripts.forEach {
            $0.source = .room
        }
        try repository.updateMeetingState(
            id: meeting.id,
            state: meeting.state
        )
        try repository.setSpeakerDisplayName(
            meetingID: meeting.id,
            speakerID: "room-7",
            displayName: "张三"
        )
        let loader = RetryAudioSourceLoader(meetingID: meeting.id)
        let diarizer = RetrySpeakerDiarizer(
            result: .success([
                .init(rawSpeakerID: "raw-a", startTime: 0, endTime: 2),
                .init(rawSpeakerID: "raw-b", startTime: 2, endTime: 4),
            ])
        )
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: loader,
            diarizer: diarizer,
            operationGate: MeetingOperationGate()
        )

        try await useCase.retry(meetingID: meeting.id)

        let loadedTracks = await loader.loadedTracks()
        XCTAssertEqual(loadedTracks, [.master])
        let transcripts = try repository.transcripts(meetingID: meeting.id)
        XCTAssertEqual(
            transcripts.map(\.text),
            ["existing first", "existing second"]
        )
        XCTAssertEqual(transcripts.map(\.speakerID), ["room-1", "room-2"])
        XCTAssertEqual(transcripts.map(\.source), [.room, .room])
        XCTAssertEqual(transcripts.map(\.sourceRevision), [5, 5])
        XCTAssertEqual(
            try repository.speakerDisplayNames(meetingID: meeting.id),
            ["room-1": "张三"]
        )
        XCTAssertEqual(
            try repository.meeting(id: meeting.id).speakerProcessingState,
            .completed
        )
    }

    func testOnlineRetryKeepsMicrophoneAsMeAndDiarizesOnlySystemTranscript()
        async throws {
        let repository = try makeRetryableMeeting(mode: .online)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.replaceTranscripts(
            meetingID: meeting.id,
            drafts: [
                draft(4, 5, "mic later", "old-me", .microphone),
                draft(1, 2, "system first", "remote", .system),
                draft(3, 4, "system second", "remote", .system),
            ],
            sourceRevision: 8
        )
        let loader = RetryAudioSourceLoader(meetingID: meeting.id)
        let diarizer = RetrySpeakerDiarizer(
            result: .success([
                .init(rawSpeakerID: "speaker-b", startTime: 0, endTime: 2.5),
                .init(rawSpeakerID: "speaker-a", startTime: 2.5, endTime: 5),
            ])
        )
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: loader,
            diarizer: diarizer,
            operationGate: MeetingOperationGate()
        )

        try await useCase.retry(meetingID: meeting.id)

        let loadedTracks = await loader.loadedTracks()
        XCTAssertEqual(loadedTracks, [.system])
        let transcripts = try repository.transcripts(meetingID: meeting.id)
        XCTAssertEqual(
            transcripts.map(\.text),
            ["system first", "system second", "mic later"]
        )
        XCTAssertEqual(
            transcripts.map(\.speakerID),
            ["remote-1", "remote-2", "me"]
        )
        XCTAssertEqual(
            transcripts.map(\.source),
            [.system, .system, .microphone]
        )
        XCTAssertEqual(transcripts.map(\.sourceRevision), [9, 9, 9])
    }

    func testOldOnlineMeetingWithoutPerTrackTagsFailsSourceUnavailable()
        async throws {
        let repository = try makeRetryableMeeting(mode: .online)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 1,
            text: "legacy mixed transcript"
        )
        let loader = RetryAudioSourceLoader(meetingID: meeting.id)
        let diarizer = RetrySpeakerDiarizer(result: .success([]))
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: loader,
            diarizer: diarizer,
            operationGate: MeetingOperationGate()
        )

        do {
            try await useCase.retry(meetingID: meeting.id)
            XCTFail("Expected sourceUnavailable")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationRetryError,
                .sourceUnavailable
            )
        }

        let loadedTracks = await loader.loadedTracks()
        let diarizerCallCount = await diarizer.callCount()
        XCTAssertEqual(loadedTracks, [])
        XCTAssertEqual(diarizerCallCount, 0)
        let reloaded = try repository.meeting(id: meeting.id)
        XCTAssertEqual(reloaded.speakerProcessingState, .degraded)
        XCTAssertEqual(
            reloaded.speakerProcessingErrorCode,
            SpeakerDiarizationRetryUseCase.sourceUnavailableCode
        )
        XCTAssertEqual(reloaded.transcripts.map(\.text), ["legacy mixed transcript"])
    }

    func testStageSpecificDiarizationFailureIsPersistedAndReturned() async throws {
        let repository = try makeRetryableMeeting(mode: .offline)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 1,
            text: "existing"
        )
        let gate = MeetingOperationGate()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meeting.id),
            diarizer: RetrySpeakerDiarizer(
                result: .failure(SpeakerDiarizationError.conversionFailed)
            ),
            operationGate: gate
        )

        do {
            try await useCase.retry(meetingID: meeting.id)
            XCTFail("Expected retry failure")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationRetryError,
                .failed(
                    errorCode: SpeakerAwareTranscriptFinalizer
                        .diarizationConversionFailedCode
                )
            )
        }

        let reloaded = try repository.meeting(id: meeting.id)
        XCTAssertEqual(reloaded.speakerProcessingState, .degraded)
        XCTAssertEqual(
            reloaded.speakerProcessingErrorCode,
            SpeakerAwareTranscriptFinalizer.diarizationConversionFailedCode
        )
        XCTAssertFalse(gate.isActive(for: meeting.id))
    }

    func testAudioSourceLoadFailurePersistsInvalidSourceStage() async throws {
        let repository = try makeRetryableMeeting(mode: .offline)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 1,
            text: "existing"
        )
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(
                meetingID: meeting.id,
                loadError: MeetingAudioSourceLoaderError.manifestNotFound
            ),
            diarizer: RetrySpeakerDiarizer(result: .success([])),
            operationGate: MeetingOperationGate()
        )

        do {
            try await useCase.retry(meetingID: meeting.id)
            XCTFail("Expected invalid-source failure")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationRetryError,
                .failed(
                    errorCode: SpeakerAwareTranscriptFinalizer
                        .diarizationInvalidSourceCode
                )
            )
        }

        XCTAssertEqual(
            try repository.meeting(id: meeting.id)
                .speakerProcessingErrorCode,
            SpeakerAwareTranscriptFinalizer.diarizationInvalidSourceCode
        )
    }

    func testConcurrentRetryIsRejectedAndCompletedMeetingCanRetryAgain()
        async throws {
        let repository = try makeRetryableMeeting(mode: .offline)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 1,
            text: "existing"
        )
        let blocker = BlockingRetrySpeakerDiarizer()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meeting.id),
            diarizer: blocker,
            operationGate: MeetingOperationGate()
        )
        let first = Task { try await useCase.retry(meetingID: meeting.id) }
        await blocker.waitUntilStarted()

        do {
            try await useCase.retry(meetingID: meeting.id)
            XCTFail("Expected operationInProgress")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationRetryError,
                .operationInProgress
            )
        }

        await blocker.resume(
            with: [.init(rawSpeakerID: "one", startTime: 0, endTime: 1)]
        )
        try await first.value
        XCTAssertEqual(
            try repository.meeting(id: meeting.id).speakerProcessingState,
            .completed
        )

        try await useCase.retry(meetingID: meeting.id)
        let retryCount = await blocker.callCount()
        XCTAssertEqual(retryCount, 2)
        XCTAssertEqual(
            try repository.meeting(id: meeting.id).speakerProcessingState,
            .completed
        )
    }

    func testCancellationLeavesMeetingDegradedAndReleasesOperationGate()
        async throws {
        let repository = try makeRetryableMeeting(mode: .offline)
        let meeting = try XCTUnwrap(repository.meetings().first)
        try repository.appendTranscript(
            meetingID: meeting.id,
            start: 0,
            end: 1,
            text: "existing"
        )
        let gate = MeetingOperationGate()
        let diarizer = CancellationRetrySpeakerDiarizer()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meeting.id),
            diarizer: diarizer,
            operationGate: gate
        )
        let operation = Task {
            try await useCase.retry(meetingID: meeting.id)
        }
        await diarizer.waitUntilStarted()
        operation.cancel()

        do {
            try await operation.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected control-flow cancellation.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let reloaded = try repository.meeting(id: meeting.id)
        XCTAssertEqual(reloaded.speakerProcessingState, .degraded)
        XCTAssertEqual(
            reloaded.speakerProcessingErrorCode,
            SpeakerDiarizationRetryUseCase.cancelledCode
        )
        XCTAssertFalse(gate.isActive(for: meeting.id))
    }

    func testCancellationRetriesOneTransientFailureSaveBeforeReturning()
        async throws {
        let saves = RetryRepositorySaveController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                try saves.save(context)
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "existing"
        )
        saves.failAfterSuccessfulSaves(1)
        let gate = MeetingOperationGate()
        let diarizer = CancellationRetrySpeakerDiarizer()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meetingID),
            diarizer: diarizer,
            operationGate: gate
        )
        let operation = Task {
            try await useCase.retry(meetingID: meetingID)
        }
        await diarizer.waitUntilStarted()
        operation.cancel()

        do {
            try await operation.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Cancellation remains the public control-flow outcome.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            SpeakerDiarizationRetryUseCase.cancelledCode
        )
        XCTAssertFalse(gate.isActive(for: meetingID))
    }

    func testRetryRecoversArchivedProcessingMeetingWithoutChangingMainData()
        async throws {
        let saves = RetryRepositorySaveController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                try saves.save(context)
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "existing"
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "existing summary",
            keyPoints: ["existing point"],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "deepseek-chat"
        )
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "complete",
            nextBatchIndex: 3
        )
        try repository.updateMeetingState(id: meetingID, state: .archived)
        let summaryID = try XCTUnwrap(meeting.summary).id
        saves.failAfterSuccessfulSaves(1, failureCount: 2)
        let gate = MeetingOperationGate()
        let cancellingDiarizer = CancellationRetrySpeakerDiarizer()
        let cancelledRetry = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meetingID),
            diarizer: cancellingDiarizer,
            operationGate: gate
        )
        let operation = Task {
            try await cancelledRetry.retry(meetingID: meetingID)
        }
        await cancellingDiarizer.waitUntilStarted()
        operation.cancel()

        do {
            try await operation.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Both recovery saves failed, so the persisted state is interrupted.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertFalse(gate.isActive(for: meetingID))

        let recoveredRetry = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meetingID),
            diarizer: RetrySpeakerDiarizer(
                result: .success([
                    .init(rawSpeakerID: "one", startTime: 0, endTime: 1)
                ])
            ),
            operationGate: gate
        )

        try await recoveredRetry.retry(meetingID: meetingID)

        let recoveredMeeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(recoveredMeeting.speakerProcessingState, .completed)
        XCTAssertNil(recoveredMeeting.speakerProcessingErrorCode)
        XCTAssertEqual(recoveredMeeting.state, .archived)
        XCTAssertEqual(recoveredMeeting.summary?.id, summaryID)
        XCTAssertEqual(recoveredMeeting.summary?.overview, "existing summary")
        XCTAssertEqual(recoveredMeeting.summary?.keyPoints, ["existing point"])
        XCTAssertEqual(recoveredMeeting.notionPageID, "existing-page")
        XCTAssertEqual(
            recoveredMeeting.notionPageURL,
            "https://www.notion.so/existing-page"
        )
        XCTAssertEqual(
            recoveredMeeting.archiveCheckpoint?.notionPageID,
            "existing-page"
        )
        let recoveredTranscripts = try repository.transcripts(
            meetingID: meetingID
        )
        XCTAssertEqual(recoveredTranscripts.map(\.text), ["existing"])
        XCTAssertEqual(recoveredTranscripts.map(\.speakerID), ["room-1"])
        XCTAssertFalse(gate.isActive(for: meetingID))
    }

    func testBeginRepositorySaveFailureReleasesOperationGate() async throws {
        let saves = RetryRepositorySaveController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                try saves.save(context)
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        saves.failAfterSuccessfulSaves(0)
        let gate = MeetingOperationGate()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meetingID),
            diarizer: RetrySpeakerDiarizer(result: .success([])),
            operationGate: gate
        )

        do {
            try await useCase.retry(meetingID: meetingID)
            XCTFail("Expected repository save failure")
        } catch {
            XCTAssertEqual(error as? RetryInjectedSaveError, .forced)
        }

        XCTAssertFalse(gate.isActive(for: meetingID))
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
    }

    func testCompleteSaveFailureDegradesMeetingAndReleasesOperationGate()
        async throws {
        let saves = RetryRepositorySaveController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                try saves.save(context)
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "existing"
        )
        saves.failAfterSuccessfulSaves(1)
        let gate = MeetingOperationGate()
        let useCase = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: RetryAudioSourceLoader(meetingID: meetingID),
            diarizer: RetrySpeakerDiarizer(
                result: .success([
                    .init(rawSpeakerID: "one", startTime: 0, endTime: 1)
                ])
            ),
            operationGate: gate
        )

        do {
            try await useCase.retry(meetingID: meetingID)
            XCTFail("Expected transcript replacement failure")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationRetryError,
                .failed(
                    errorCode: SpeakerDiarizationRetryUseCase
                        .transcriptReplacementFailedCode
                )
            )
        }

        XCTAssertFalse(gate.isActive(for: meetingID))
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            SpeakerDiarizationRetryUseCase.transcriptReplacementFailedCode
        )
        XCTAssertEqual(meeting.transcripts.map(\.text), ["existing"])
    }

    private func makeRetryableMeeting(
        mode: MeetingMode
    ) throws -> MeetingRepository {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: mode,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            SpeakerAwareTranscriptFinalizer.diarizationInferenceFailedCode
        try repository.updateMeetingState(id: meetingID, state: .ready)
        return repository
    }

    private func draft(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String,
        _ speakerID: String?,
        _ source: TranscriptAudioSource
    ) -> AttributedTranscriptDraft {
        AttributedTranscriptDraft(
            transcript: .init(startTime: start, endTime: end, text: text),
            speakerID: speakerID,
            source: source
        )
    }
}

private enum RetryInjectedSaveError: Error, Equatable {
    case forced
}

@MainActor
private final class RetryRepositorySaveController {
    private var successfulSavesBeforeFailure: Int?
    private var remainingFailureCount = 0

    func failAfterSuccessfulSaves(
        _ count: Int,
        failureCount: Int = 1
    ) {
        successfulSavesBeforeFailure = count
        remainingFailureCount = failureCount
    }

    func save(_ context: SwiftData.ModelContext) throws {
        if successfulSavesBeforeFailure == 0,
           remainingFailureCount > 0 {
            remainingFailureCount -= 1
            if remainingFailureCount == 0 {
                successfulSavesBeforeFailure = nil
            }
            throw RetryInjectedSaveError.forced
        }
        if let remaining = successfulSavesBeforeFailure {
            successfulSavesBeforeFailure = remaining - 1
        }
        try context.save()
    }
}

private actor RetryAudioSourceLoader: MeetingTrackAudioSourceLoading {
    private let meetingID: UUID
    private let loadError: Error?
    private var tracks: [AudioTrack] = []

    init(meetingID: UUID, loadError: Error? = nil) {
        self.meetingID = meetingID
        self.loadError = loadError
    }

    func load(meetingID: UUID, track: AudioTrack) async throws
        -> MeetingAudioSource {
        tracks.append(track)
        if let loadError { throw loadError }
        return MeetingAudioSource(
            meetingID: meetingID,
            resolvedSegments: [],
            segmentFrameCounts: [],
            sampleRate: 48_000,
            channelCount: 1,
            totalFrames: 0,
            manifestSignature: "manifest-\(track.rawValue)",
            identitySignature: "identity-\(track.rawValue)"
        )
    }

    func confirmSegmentIdentity(
        in source: MeetingAudioSource,
        segmentIndex: Int
    ) async throws {
        _ = source
        _ = segmentIndex
    }

    func loadedTracks() -> [AudioTrack] {
        tracks
    }
}

private actor RetrySpeakerDiarizer: SpeakerDiarizing {
    private let result: Result<[SpeakerInterval], Error>
    private var calls = 0

    init(result: Result<[SpeakerInterval], Error>) {
        self.result = result
    }

    func diarize(source: MeetingAudioSource) async throws
        -> [SpeakerInterval] {
        _ = source
        calls += 1
        return try result.get()
    }

    func callCount() -> Int { calls }
}

private actor BlockingRetrySpeakerDiarizer: SpeakerDiarizing {
    private var calls = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter:
        CheckedContinuation<[SpeakerInterval], Error>?
    private var nextResult: [SpeakerInterval]?

    func diarize(source: MeetingAudioSource) async throws
        -> [SpeakerInterval] {
        _ = source
        calls += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if let nextResult {
            self.nextResult = nil
            return nextResult
        }
        return try await withCheckedThrowingContinuation { continuation in
            resultWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func resume(with intervals: [SpeakerInterval]) {
        nextResult = intervals
        if let resultWaiter {
            self.resultWaiter = nil
            resultWaiter.resume(returning: intervals)
        }
    }

    func callCount() -> Int { calls }
}

private actor CancellationRetrySpeakerDiarizer: SpeakerDiarizing {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func diarize(source: MeetingAudioSource) async throws
        -> [SpeakerInterval] {
        _ = source
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        while true {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }
}
