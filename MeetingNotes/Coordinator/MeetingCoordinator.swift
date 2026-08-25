import Foundation

enum MeetingCoordinatorError: Error, Equatable, Sendable {
    case permissionDenied(Set<CapturePermission>)
    case sessionUnavailable
    case operationInProgress
    case capturePipelineFailed
    case transcriptPersistenceFailed
}

private enum SourceDegradationReason: Equatable, Sendable {
    case appendFailed(AudioTrack)
    case finishFailed(AudioTrack)
    case noFrames(AudioTrack)
    case sustainedSilence(AudioTrack)

    var errorCode: String {
        switch self {
        case let .appendFailed(track):
            "source_track_write_failed_\(track.rawValue)"
        case let .finishFailed(track):
            "source_track_finish_failed_\(track.rawValue)"
        case let .noFrames(track):
            "source_track_no_frames_\(track.rawValue)"
        case let .sustainedSilence(track):
            "source_track_sustained_silence_\(track.rawValue)"
        }
    }

    var precedence: (failureClass: Int, track: Int) {
        let failureClass: Int
        let track: AudioTrack
        switch self {
        case let .appendFailed(failedTrack):
            failureClass = 0
            track = failedTrack
        case let .finishFailed(failedTrack):
            failureClass = 1
            track = failedTrack
        case let .noFrames(failedTrack):
            failureClass = 2
            track = failedTrack
        case let .sustainedSilence(failedTrack):
            failureClass = 3
            track = failedTrack
        }
        let trackPrecedence = switch track {
        case .microphone: 0
        case .system: 1
        case .master: 2
        }
        return (failureClass, trackPrecedence)
    }
}

struct MeetingCoordinatorSnapshot: Equatable, Sendable {
    let state: RecordingState
    let meetingID: UUID?
    let mode: MeetingMode?
    let activeTime: TimeInterval
    let bookmarkCount: Int
    let captureFailed: Bool
    let captureHealthCode: MeetingCaptureHealthCode?
}

actor MeetingCoordinator {
    static let productionTranscriptionChunkSampleCount =
        10 * Int(AudioSegmentManifest.transcriptionSampleRate)

    private let dependencies: MeetingCoordinatorDependencies
    private let transcriptionChunkSampleCount: Int
    private var stateMachine = RecordingStateMachine()
    private var meetingID: UUID?
    private var mode: MeetingMode?
    private var speakerDiarizationRequested = false
    private var capture: (any AudioCaptureSource)?
    private var masterWriter: (any MeetingAudioWriting)?
    private var sourceWriters: [AudioTrack: any MeetingAudioWriting] = [:]
    private var transcriber: (any MeetingTranscriptionQueueing)?
    private var fixedTranscriptionService: (any TranscriptionService)?
    private var timeline: ActiveRecordingTimeline?
    private var streamTask: Task<Void, Never>?
    private var transcriptPersistenceTask: Task<Bool, Never>?
    private var preferredEncounteredSourceDegradation:
        SourceDegradationReason?
    private var pendingSourceDegradationPersistence:
        SourceDegradationReason?
    private var sourceDegradationPersistenceInProgress = false
    private var pendingTranscriptionSamples: [Float] = []
    private var nextTranscriptionSampleOffset = 0
    private var totalSampleCount = 0
    private var bookmarkCount = 0
    private var finalActiveDuration: TimeInterval = 0
    private var captureFailed = false
    private var captureHealthCode: MeetingCaptureHealthCode?
    private var captureHealthMonitors: [AudioTrack: CaptureHealthMonitor] = [:]
    private var captureHealthTask: Task<Void, Never>?
    private var captureHealthGeneration: UInt64 = 0
    private var captureHealthPipelineFailed = false
    private var captureInterruptionFinalizationScheduled = false
    private var lifecycleOperationInProgress = false
    private var discardRequestedMeetingIDs: Set<UUID> = []
    private var lifecycleCompletionWaiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        dependencies: MeetingCoordinatorDependencies,
        transcriptionChunkSampleCount: Int = productionTranscriptionChunkSampleCount
    ) {
        self.dependencies = dependencies
        self.transcriptionChunkSampleCount = max(1, transcriptionChunkSampleCount)
    }

    func snapshot() async -> MeetingCoordinatorSnapshot {
        let activeTime: TimeInterval
        if let timeline {
            activeTime = timeline.activeTime(
                at: await dependencies.clock.monotonicNow()
            )
        } else {
            activeTime = finalActiveDuration
        }
        return MeetingCoordinatorSnapshot(
            state: stateMachine.state,
            meetingID: meetingID,
            mode: mode,
            activeTime: activeTime,
            bookmarkCount: bookmarkCount,
            captureFailed: captureFailed,
            captureHealthCode: captureHealthCode
        )
    }

    func prepareForDeletion(id: UUID) async throws {
        guard meetingID == id else { return }
        discardRequestedMeetingIDs.insert(id)

        if lifecycleOperationInProgress {
            if let capture {
                await capture.stop()
            }
            if let transcriber {
                await transcriber.cancel()
            }
            await waitForLifecycleCompletion()
        }

        guard meetingID == id else {
            discardRequestedMeetingIDs.remove(id)
            return
        }

        try beginLifecycleOperation()
        defer { endLifecycleOperation() }
        await discardActiveMeeting(id: id)
        discardRequestedMeetingIDs.remove(id)
    }

    @discardableResult
    func start(mode: MeetingMode) async throws -> UUID {
        try await start(mode: mode, onMeetingCreated: { _ in })
    }

    @discardableResult
    func start(
        mode: MeetingMode,
        onMeetingCreated: @Sendable @escaping (UUID) async -> Void
    ) async throws -> UUID {
        try beginLifecycleOperation()
        defer { endLifecycleOperation() }
        resetStrandedFinalizationBeforeNewStart()
        var preparingMachine = stateMachine
        try preparingMachine.send(.prepare)

        let permissionStatuses = await dependencies.permissions
            .requestRequiredPermissions(for: mode)
        let deniedPermissions = Set(
            CapturePermissionClient.requiredPermissions(for: mode).filter {
                permissionStatuses[$0] != .authorized
            }
        )
        guard deniedPermissions.isEmpty else {
            resetAfterFailedStart()
            throw MeetingCoordinatorError.permissionDenied(deniedPermissions)
        }

        var newMeetingID: UUID?
        var newCapture: (any AudioCaptureSource)?
        var newMasterWriter: (any MeetingAudioWriting)?
        var newSourceWriters: [AudioTrack: any MeetingAudioWriting] = [:]
        var newTranscriber: (any MeetingTranscriptionQueueing)?

        do {
            let createdTranscriber = try await dependencies.transcriptionFactory
                .makeQueue()
            newTranscriber = createdTranscriber
            try Task.checkCancellation()

            let startedAt = await dependencies.clock.now()
            try Task.checkCancellation()
            let speakerDiarizationRequested = await dependencies
                .speakerDiarizationPreference
                .isSpeakerDiarizationEnabled()
            try Task.checkCancellation()

            stateMachine = preparingMachine
            try Task.checkCancellation()
            let createdID = try await dependencies.repository.createMeeting(
                mode: mode,
                startedAt: startedAt,
                speakerDiarizationRequested: speakerDiarizationRequested
            )
            newMeetingID = createdID
            try Task.checkCancellation()
            meetingID = createdID
            self.mode = mode
            self.speakerDiarizationRequested =
                speakerDiarizationRequested
            await onMeetingCreated(createdID)
            try throwIfDiscardRequested(for: createdID)
            let writerSampleRate = PCMConverter.playbackSampleRate
            let createdMasterWriter = try await dependencies.writerFactory.makeWriter(
                meetingID: createdID,
                track: .master,
                sampleRate: writerSampleRate
            )
            newMasterWriter = createdMasterWriter
            masterWriter = createdMasterWriter
            try throwIfDiscardRequested(for: createdID)
            if mode == .online {
                for track in [AudioTrack.microphone, .system] {
                    newSourceWriters[track] = try await dependencies.writerFactory
                        .makeWriter(
                            meetingID: createdID,
                            track: track,
                            sampleRate: writerSampleRate
                        )
                    sourceWriters = newSourceWriters
                    try throwIfDiscardRequested(for: createdID)
                }
            }
            transcriber = createdTranscriber
            try throwIfDiscardRequested(for: createdID)
            let createdFixedTranscriptionService =
                await createdTranscriber.fixedTranscriptionService()
            fixedTranscriptionService = createdFixedTranscriptionService
            try throwIfDiscardRequested(for: createdID)
            let createdCapture = try await dependencies.captureFactory
                .makeCapture(for: mode)
            newCapture = createdCapture
            capture = createdCapture
            try throwIfDiscardRequested(for: createdID)
            let stream = try await createdCapture.start()
            try throwIfDiscardRequested(for: createdID)
            let timelineStart = await dependencies.clock.monotonicNow()
            try throwIfDiscardRequested(for: createdID)

            var recordingMachine = stateMachine
            try recordingMachine.send(.start)
            try await dependencies.repository.updateState(
                meetingID: createdID,
                state: .recording
            )
            try throwIfDiscardRequested(for: createdID)

            meetingID = createdID
            self.mode = mode
            self.speakerDiarizationRequested =
                speakerDiarizationRequested
            capture = createdCapture
            masterWriter = createdMasterWriter
            sourceWriters = newSourceWriters
            transcriber = createdTranscriber
            fixedTranscriptionService = createdFixedTranscriptionService
            timeline = ActiveRecordingTimeline(startedAt: timelineStart)
            stateMachine = recordingMachine
            bookmarkCount = 0
            finalActiveDuration = 0
            captureFailed = false
            captureHealthCode = nil
            captureHealthPipelineFailed = false
            prepareCaptureHealthMonitoring(for: mode)
            pendingTranscriptionSamples.removeAll(keepingCapacity: true)
            nextTranscriptionSampleOffset = 0
            totalSampleCount = 0
            let transcriptUpdates = await createdTranscriber.updates()
            let repository = dependencies.repository
            transcriptPersistenceTask = Task {
                var allWritesSucceeded = true
                for await draft in transcriptUpdates {
                    do {
                        try await repository.appendTranscript(
                            meetingID: createdID,
                            draft: draft
                        )
                    } catch {
                        allWritesSucceeded = false
                    }
                }
                return allWritesSucceeded
            }
            streamTask = makeStreamTask(stream)
            await dependencies.recordingPresentation.start(
                meetingID: createdID,
                monotonicTime: timelineStart
            )
            try throwIfDiscardRequested(for: createdID)
            await dependencies.panel.show()
            try throwIfDiscardRequested(for: createdID)
            return createdID
        } catch {
            let discarded = newMeetingID.map {
                discardRequestedMeetingIDs.contains($0)
            } ?? false
            if let newCapture {
                await newCapture.stop()
            }
            for track in [AudioTrack.microphone, .system] {
                if let writer = newSourceWriters[track] {
                    _ = try? await writer.finish()
                }
            }
            if let newMasterWriter {
                _ = try? await newMasterWriter.finish()
            }
            if let newTranscriber {
                if discarded {
                    await newTranscriber.cancel()
                } else {
                    await newTranscriber.drain()
                }
                await newTranscriber.finishUpdates()
            }
            _ = await transcriptPersistenceTask?.value
            if let newMeetingID, discarded {
                await dependencies.panel.hide()
                await dependencies.recordingPresentation.clear(
                    meetingID: newMeetingID
                )
            } else if let newMeetingID {
                try? await dependencies.repository.deleteMeeting(
                    meetingID: newMeetingID
                )
            }
            resetAfterFailedStart()
            if let newMeetingID {
                discardRequestedMeetingIDs.remove(newMeetingID)
            }
            if discarded {
                throw CancellationError()
            }
            throw error
        }
    }

    func pauseOrResume() async throws {
        try beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard let meetingID, let capture, let timeline else {
            throw MeetingCoordinatorError.sessionUnavailable
        }
        let now = await dependencies.clock.monotonicNow()

        switch stateMachine.state {
        case .recording:
            var pausedMachine = stateMachine
            var pausedTimeline = timeline
            try pausedMachine.send(.pause)
            try pausedTimeline.pause(at: now)
            try await capture.pause()
            try throwIfDiscardRequested(for: meetingID)
            guard !captureFailed else {
                throw MeetingCoordinatorError.capturePipelineFailed
            }
            do {
                try await dependencies.repository.updateState(
                    meetingID: meetingID,
                    state: .paused
                )
            } catch {
                try? await capture.resume()
                throw error
            }
            stateMachine = pausedMachine
            self.timeline = pausedTimeline
            await dependencies.recordingPresentation.pause(
                meetingID: meetingID,
                activeDuration: pausedTimeline.activeTime(at: now)
            )

        case .paused:
            var recordingMachine = stateMachine
            var recordingTimeline = timeline
            try recordingMachine.send(.resume)
            try recordingTimeline.resume(at: now)
            try await capture.resume()
            try throwIfDiscardRequested(for: meetingID)
            guard !captureFailed else {
                throw MeetingCoordinatorError.capturePipelineFailed
            }
            do {
                try await dependencies.repository.updateState(
                    meetingID: meetingID,
                    state: .recording
                )
            } catch {
                try? await capture.pause()
                throw error
            }
            stateMachine = recordingMachine
            self.timeline = recordingTimeline
            await dependencies.recordingPresentation.resume(
                meetingID: meetingID,
                activeDuration: recordingTimeline.activeTime(at: now),
                monotonicTime: now
            )

        default:
            var invalidMachine = stateMachine
            try invalidMachine.send(.pause)
        }
    }

    func bookmark() async throws {
        try beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard let meetingID, let timeline else {
            throw MeetingCoordinatorError.sessionUnavailable
        }
        var bookmarkedMachine = stateMachine
        try bookmarkedMachine.send(.bookmark)
        let timestamp = timeline.activeTime(
            at: await dependencies.clock.monotonicNow()
        )
        try throwIfDiscardRequested(for: meetingID)
        try await dependencies.repository.appendBookmark(
            meetingID: meetingID,
            timestamp: timestamp
        )
        stateMachine = bookmarkedMachine
        bookmarkCount += 1
    }

    func stop() async throws {
        if captureInterruptionFinalizationScheduled {
            await finalizeInterruptedCaptureIfNeeded()
            return
        }
        try beginLifecycleOperation()
        defer { endLifecycleOperation() }
        var finalizingMachine = stateMachine
        try finalizingMachine.send(.stop)
        guard let meetingID,
              let mode,
              let capture,
              let masterWriter,
              let transcriber,
              let timeline else {
            throw MeetingCoordinatorError.sessionUnavailable
        }

        let stoppedAt = await dependencies.clock.monotonicNow()
        let activeDuration = timeline.activeTime(at: stoppedAt)
        await evaluateCaptureHealth(at: activeDuration)
        invalidateCaptureHealthMonitoring()
        try await dependencies.repository.updateState(
            meetingID: meetingID,
            state: .finalizing
        )
        stateMachine = finalizingMachine
        await dependencies.recordingPresentation.finish(
            meetingID: meetingID,
            activeDuration: activeDuration
        )
        await dependencies.panel.hide()
        var transcriptionUpdatesFinished = false
        var writersFinished = false

        do {
            let task = streamTask
            await capture.stop()
            await task?.value
            try throwIfDiscardRequested(for: meetingID)
            await finishSurvivingSourceWriters(meetingID: meetingID)
            _ = try await masterWriter.finish()
            writersFinished = true
            try throwIfDiscardRequested(for: meetingID)
            await enqueueRemainingTranscriptionSamples(using: transcriber)
            await transcriber.drain()
            await transcriber.finishUpdates()
            transcriptionUpdatesFinished = true
            try throwIfDiscardRequested(for: meetingID)
            if let transcriptPersistenceTask,
               !(await transcriptPersistenceTask.value) {
                throw MeetingCoordinatorError.transcriptPersistenceFailed
            }
            if captureHealthPipelineFailed {
                throw MeetingCoordinatorError.capturePipelineFailed
            }

            let speakerDegradationCode: String?
            if preferredSourceDegradation() == nil {
                try throwIfDiscardRequested(for: meetingID)
                let provisional = await transcriber.transcripts()
                try throwIfDiscardRequested(for: meetingID)
                if speakerDiarizationRequested {
                    try? await dependencies.repository
                        .markSpeakerProcessingStarted(meetingID: meetingID)
                }
                let speakerOutcome: SpeakerFinalizationOutcome
                if let fixedTranscriptionService {
                    speakerOutcome = await dependencies.speakerFinalizer
                        .finalize(
                            meetingID: meetingID,
                            mode: mode,
                            diarizationRequested:
                                speakerDiarizationRequested,
                            provisional: provisional,
                            transcriptionService:
                                fixedTranscriptionService
                        )
                } else {
                    speakerOutcome = await dependencies.speakerFinalizer
                        .finalize(
                            meetingID: meetingID,
                            mode: mode,
                            diarizationRequested:
                                speakerDiarizationRequested,
                            provisional: provisional
                        )
                }
                try throwIfDiscardRequested(for: meetingID)
                speakerDegradationCode =
                    await applySpeakerFinalizationOutcome(
                        speakerOutcome,
                        meetingID: meetingID
                    )
            } else {
                // A source writer may still have a valid but truncated
                // manifest. Never let that partial track replace the complete
                // mixed provisional transcript.
                speakerDegradationCode = nil
            }
            try throwIfDiscardRequested(for: meetingID)
            let endedAt = await dependencies.clock.now()
            try throwIfDiscardRequested(for: meetingID)
            try await dependencies.repository.finalizeMeeting(
                meetingID: meetingID,
                endedAt: endedAt,
                activeDuration: activeDuration,
                sourceDegradationErrorCode:
                    preferredSourceDegradation()?.errorCode
                    ?? speakerDegradationCode
            )
            preferredEncounteredSourceDegradation = nil
            pendingSourceDegradationPersistence = nil
            var readyMachine = stateMachine
            try readyMachine.send(.finalized)
            stateMachine = readyMachine
            resetAfterSuccessfulStop()
        } catch {
            if discardRequestedMeetingIDs.contains(meetingID) {
                if !writersFinished {
                    for track in [AudioTrack.microphone, .system] {
                        if let writer = sourceWriters[track] {
                            _ = try? await writer.finish()
                        }
                    }
                    _ = try? await masterWriter.finish()
                }
                await transcriber.cancel()
                await transcriber.finishUpdates()
                _ = await transcriptPersistenceTask?.value
                await dependencies.recordingPresentation.clear(
                    meetingID: meetingID
                )
                resetAfterFailedStart()
                discardRequestedMeetingIDs.remove(meetingID)
                throw CancellationError()
            }
            finalActiveDuration = activeDuration
            if !transcriptionUpdatesFinished {
                await transcriber.drain()
                await transcriber.finishUpdates()
            }
            _ = await transcriptPersistenceTask?.value
            releaseActiveResources()
            throw error
        }
    }

    private func makeStreamTask(
        _ stream: AsyncThrowingStream<CapturedAudioPacket, Error>
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await packet in stream {
                    try await self?.consume(packet)
                }
            } catch {
                await self?.handleCaptureFailure(error)
            }
        }
    }

    private func consume(_ packet: CapturedAudioPacket) async throws {
        guard let masterWriter, let transcriber else {
            return
        }
        await ingestCaptureHealth(packet)
        let frame = packet.master
        let writerTimestamp = Double(totalSampleCount)
            / frame.sampleRate
        try await masterWriter.append(
            storageFrame(from: frame, timestamp: writerTimestamp)
        )

        for track in [AudioTrack.microphone, .system] {
            guard let sourceFrame = packet.sourceFrames[track],
                  let writer = sourceWriters[track] else {
                continue
            }
            do {
                try await writer.append(
                    storageFrame(
                        from: sourceFrame,
                        timestamp: writerTimestamp
                    )
                )
            } catch {
                await handleSourceWriterFailure(
                    track: track,
                    meetingID: meetingID
                )
            }
        }

        totalSampleCount += frame.samples.count
        let transcriptionInput: [Float]
        if let samples = frame.transcriptionSamples {
            guard abs(
                (frame.transcriptionSampleRate ?? 0)
                    - AudioSegmentManifest.transcriptionSampleRate
            ) < 0.001 else {
                throw MeetingCoordinatorError.capturePipelineFailed
            }
            transcriptionInput = samples
        } else {
            guard abs(
                frame.sampleRate - AudioSegmentManifest.transcriptionSampleRate
            ) < 0.001 else {
                throw MeetingCoordinatorError.capturePipelineFailed
            }
            transcriptionInput = frame.samples
        }
        pendingTranscriptionSamples.append(contentsOf: transcriptionInput)

        while pendingTranscriptionSamples.count >= transcriptionChunkSampleCount {
            let chunk = Array(
                pendingTranscriptionSamples.prefix(transcriptionChunkSampleCount)
            )
            pendingTranscriptionSamples.removeFirst(transcriptionChunkSampleCount)
            let startingAt = Double(nextTranscriptionSampleOffset)
                / AudioSegmentManifest.transcriptionSampleRate
            nextTranscriptionSampleOffset += chunk.count
            await transcriber.enqueue(samples: chunk, startingAt: startingAt)
        }
    }

    private func storageFrame(
        from frame: CapturedAudioFrame,
        timestamp: TimeInterval
    ) -> CapturedAudioFrame {
        CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            samples: frame.samples
        )
    }

    private func handleSourceWriterFailure(
        track: AudioTrack,
        meetingID: UUID?
    ) async {
        guard let writer = sourceWriters.removeValue(forKey: track) else {
            return
        }
        _ = try? await writer.finish()
        guard let meetingID else {
            return
        }
        await recordSourceDegradation(
            .appendFailed(track),
            meetingID: meetingID
        )
    }

    private func finishSurvivingSourceWriters(meetingID: UUID) async {
        for track in [AudioTrack.microphone, .system] {
            guard let writer = sourceWriters.removeValue(forKey: track) else {
                continue
            }
            do {
                _ = try await writer.finish()
            } catch {
                await recordSourceDegradation(
                    .finishFailed(track),
                    meetingID: meetingID
                )
            }
        }
    }

    private func recordSourceDegradation(
        _ reason: SourceDegradationReason,
        meetingID: UUID
    ) async {
        if let preferredEncounteredSourceDegradation,
           !reasonOutranks(
               reason,
               preferredEncounteredSourceDegradation
           ) {
            return
        }
        preferredEncounteredSourceDegradation = reason
        pendingSourceDegradationPersistence = reason
        try? await persistPendingSourceDegradations(meetingID: meetingID)
    }

    private func persistPendingSourceDegradations(
        meetingID: UUID
    ) async throws {
        guard !sourceDegradationPersistenceInProgress else {
            return
        }
        sourceDegradationPersistenceInProgress = true
        defer { sourceDegradationPersistenceInProgress = false }

        while let reason = pendingSourceDegradationPersistence {
            do {
                try await dependencies.repository
                    .markSpeakerProcessingDegraded(
                        meetingID: meetingID,
                        errorCode: reason.errorCode
                    )
            } catch {
                if pendingSourceDegradationPersistence != reason {
                    continue
                }
                throw error
            }
            if pendingSourceDegradationPersistence == reason {
                pendingSourceDegradationPersistence = nil
            }
        }
    }

    private func preferredSourceDegradation()
        -> SourceDegradationReason? {
        preferredEncounteredSourceDegradation
    }

    private func reasonOutranks(
        _ lhs: SourceDegradationReason,
        _ rhs: SourceDegradationReason
    ) -> Bool {
        if lhs.precedence.failureClass
            != rhs.precedence.failureClass {
            return lhs.precedence.failureClass
                < rhs.precedence.failureClass
        }
        return lhs.precedence.track < rhs.precedence.track
    }

    private func enqueueRemainingTranscriptionSamples(
        using transcriber: any MeetingTranscriptionQueueing
    ) async {
        guard !pendingTranscriptionSamples.isEmpty else {
            return
        }
        let chunk = pendingTranscriptionSamples
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        let startingAt = Double(nextTranscriptionSampleOffset)
            / AudioSegmentManifest.transcriptionSampleRate
        nextTranscriptionSampleOffset += chunk.count
        await transcriber.enqueue(samples: chunk, startingAt: startingAt)
    }

    private func applySpeakerFinalizationOutcome(
        _ outcome: SpeakerFinalizationOutcome,
        meetingID: UUID
    ) async -> String? {
        switch outcome {
        case .unchanged:
            return nil
        case let .replacement(drafts, sourceRevision):
            return await persistSpeakerReplacement(
                drafts,
                sourceRevision: sourceRevision,
                degradationCode: nil,
                meetingID: meetingID
            )
        case let .degraded(
            replacement,
            sourceRevision,
            errorCode
        ):
            if let replacement, let sourceRevision {
                return await persistSpeakerReplacement(
                    replacement,
                    sourceRevision: sourceRevision,
                    degradationCode: errorCode,
                    meetingID: meetingID
                )
            }
            return await persistSpeakerDegradation(
                errorCode,
                meetingID: meetingID
            )
        }
    }

    private func persistSpeakerReplacement(
        _ drafts: [AttributedTranscriptDraft],
        sourceRevision: Int,
        degradationCode: String?,
        meetingID: UUID
    ) async -> String? {
        do {
            try await dependencies.repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: drafts,
                sourceRevision: sourceRevision
            )
        } catch {
            return await persistSpeakerDegradation(
                "speaker_transcript_replacement_failed",
                meetingID: meetingID
            )
        }
        guard let degradationCode else {
            return nil
        }
        return await persistSpeakerDegradation(
            degradationCode,
            meetingID: meetingID
        )
    }

    private func persistSpeakerDegradation(
        _ errorCode: String,
        meetingID: UUID
    ) async -> String? {
        guard preferredSourceDegradation() == nil else {
            return errorCode
        }
        do {
            try await dependencies.repository.markSpeakerProcessingDegraded(
                meetingID: meetingID,
                errorCode: errorCode
            )
            return nil
        } catch {
            return errorCode
        }
    }

    private func handleCaptureFailure(_ error: Error) async {
        _ = error
        captureFailed = true
        guard !captureInterruptionFinalizationScheduled else {
            return
        }
        captureInterruptionFinalizationScheduled = true
        Task { [weak self] in
            await self?.finalizeInterruptedCaptureIfNeeded()
        }
    }

    private func finalizeInterruptedCaptureIfNeeded() async {
        await waitForLifecycleCompletion()
        guard captureFailed,
              stateMachine.state == .recording
                || stateMachine.state == .paused,
              let meetingID,
              let capture,
              let masterWriter,
              let transcriber,
              let timeline else {
            captureInterruptionFinalizationScheduled = false
            return
        }

        do {
            try beginLifecycleOperation()
        } catch {
            captureInterruptionFinalizationScheduled = false
            return
        }
        defer { endLifecycleOperation() }

        let stoppedAt = await dependencies.clock.monotonicNow()
        let activeDuration = timeline.activeTime(at: stoppedAt)
        finalActiveDuration = activeDuration
        invalidateCaptureHealthMonitoring()
        try? await dependencies.repository.updateState(
            meetingID: meetingID,
            state: .finalizing
        )
        await dependencies.recordingPresentation.finish(
            meetingID: meetingID,
            activeDuration: activeDuration
        )
        await dependencies.panel.hide()
        await capture.stop()
        await finishSurvivingSourceWriters(meetingID: meetingID)
        _ = try? await masterWriter.finish()
        await enqueueRemainingTranscriptionSamples(using: transcriber)
        await transcriber.drain()
        await transcriber.finishUpdates()
        _ = await transcriptPersistenceTask?.value

        let endedAt = await dependencies.clock.now()
        try? await dependencies.repository.finalizeInterruptedMeeting(
            meetingID: meetingID,
            endedAt: endedAt,
            activeDuration: activeDuration,
            lastErrorCode: "capture_interrupted"
        )
        await dependencies.captureInterruptionReporter.captureInterrupted(
            meetingID: meetingID
        )

        resetAfterFailedStart()
    }

    private func prepareCaptureHealthMonitoring(for mode: MeetingMode) {
        captureHealthMonitors = [
            .master: CaptureHealthMonitor(startedAt: 0)
        ]
        if mode == .online {
            captureHealthMonitors[.microphone] =
                CaptureHealthMonitor(startedAt: 0)
            captureHealthMonitors[.system] =
                CaptureHealthMonitor(startedAt: 0)
        }
        captureHealthGeneration &+= 1
        let generation = captureHealthGeneration
        let checks = dependencies.captureHealthScheduler.checks()
        captureHealthTask = Task { [weak self] in
            for await _ in checks {
                guard !Task.isCancelled else { return }
                await self?.runCaptureHealthCheck(generation: generation)
            }
        }
    }

    private func invalidateCaptureHealthMonitoring() {
        captureHealthGeneration &+= 1
        captureHealthTask?.cancel()
        captureHealthTask = nil
    }

    private func runCaptureHealthCheck(generation: UInt64) async {
        guard generation == captureHealthGeneration,
              stateMachine.state == .recording,
              let timeline else {
            return
        }
        let now = await dependencies.clock.monotonicNow()
        guard generation == captureHealthGeneration else { return }
        await evaluateCaptureHealth(at: timeline.activeTime(at: now))
    }

    private func ingestCaptureHealth(_ packet: CapturedAudioPacket) async {
        guard let timeline else { return }
        let now = await dependencies.clock.monotonicNow()
        let activeTime = timeline.activeTime(at: now)
        captureHealthMonitors[.master]?.ingest(
            samples: packet.master.samples,
            at: activeTime
        )
        guard mode == .online else { return }
        for track in [AudioTrack.microphone, .system] {
            guard let frame = packet.sourceFrames[track] else { continue }
            captureHealthMonitors[track]?.ingest(
                samples: frame.samples,
                at: activeTime
            )
        }
    }

    private func evaluateCaptureHealth(at activeTime: TimeInterval) async {
        guard let mode,
              let masterStatus = captureHealthMonitors[.master]?
                .status(at: activeTime) else {
            return
        }
        if masterStatus == .noFrames {
            await markCaptureHealthPipelineFailed(.masterNoFrames)
            return
        }

        if mode == .offline {
            if masterStatus == .sustainedSilence {
                retainCaptureHealthCode(.masterSustainedSilence)
            }
            return
        }

        guard let microphoneStatus = captureHealthMonitors[.microphone]?
                .status(at: activeTime),
              let systemStatus = captureHealthMonitors[.system]?
                .status(at: activeTime) else {
            return
        }
        let microphoneIssue = healthIssue(
            status: microphoneStatus,
            track: .microphone
        )
        let systemIssue = healthIssue(
            status: systemStatus,
            track: .system
        )

        if microphoneIssue != nil, systemIssue != nil {
            await markCaptureHealthPipelineFailed(.bothSourcesDegraded)
            return
        }
        if let microphoneIssue {
            await recordCaptureHealthDegradation(
                microphoneIssue
            )
        } else if let systemIssue {
            await recordCaptureHealthDegradation(
                systemIssue
            )
        }
    }

    private func healthIssue(
        status: CaptureHealthStatus,
        track: AudioTrack
    ) -> (code: MeetingCaptureHealthCode, reason: SourceDegradationReason)? {
        switch (track, status) {
        case (.microphone, .noFrames):
            (.microphoneNoFrames, .noFrames(.microphone))
        case (.microphone, .sustainedSilence):
            (
                .microphoneSustainedSilence,
                .sustainedSilence(.microphone)
            )
        case (.system, .noFrames):
            (.systemNoFrames, .noFrames(.system))
        case (.system, .sustainedSilence):
            (.systemSustainedSilence, .sustainedSilence(.system))
        default:
            nil
        }
    }

    private func recordCaptureHealthDegradation(
        _ issue: (
            code: MeetingCaptureHealthCode,
            reason: SourceDegradationReason
        )
    ) async {
        retainCaptureHealthCode(issue.code)
        guard let meetingID else { return }
        await recordSourceDegradation(issue.reason, meetingID: meetingID)
    }

    private func markCaptureHealthPipelineFailed(
        _ code: MeetingCaptureHealthCode
    ) async {
        retainCaptureHealthCode(code, isPipelineFailure: true)
        guard !captureHealthPipelineFailed else { return }
        captureHealthPipelineFailed = true
        await handleCaptureFailure(
            MeetingCoordinatorError.capturePipelineFailed
        )
    }

    private func retainCaptureHealthCode(
        _ code: MeetingCaptureHealthCode,
        isPipelineFailure: Bool = false
    ) {
        if isPipelineFailure || captureHealthCode == nil {
            captureHealthCode = code
        }
    }

    private func beginLifecycleOperation() throws {
        guard !lifecycleOperationInProgress else {
            throw MeetingCoordinatorError.operationInProgress
        }
        lifecycleOperationInProgress = true
    }

    private func endLifecycleOperation() {
        lifecycleOperationInProgress = false
        let waiters = lifecycleCompletionWaiters
        lifecycleCompletionWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForLifecycleCompletion() async {
        guard lifecycleOperationInProgress else { return }
        await withCheckedContinuation { continuation in
            lifecycleCompletionWaiters.append(continuation)
        }
    }

    private func throwIfDiscardRequested(for meetingID: UUID) throws {
        if discardRequestedMeetingIDs.contains(meetingID) {
            throw CancellationError()
        }
    }

    private func discardActiveMeeting(id: UUID) async {
        invalidateCaptureHealthMonitoring()
        let captureTask = streamTask
        if let capture {
            await capture.stop()
        }
        await captureTask?.value

        if let transcriber {
            await transcriber.cancel()
            await transcriber.finishUpdates()
        }
        _ = await transcriptPersistenceTask?.value

        for track in [AudioTrack.microphone, .system] {
            if let writer = sourceWriters[track] {
                _ = try? await writer.finish()
            }
        }
        if let masterWriter {
            _ = try? await masterWriter.finish()
        }

        await dependencies.panel.hide()
        await dependencies.recordingPresentation.clear(meetingID: id)
        resetAfterFailedStart()
    }

    private func resetAfterFailedStart() {
        stateMachine = RecordingStateMachine()
        meetingID = nil
        mode = nil
        speakerDiarizationRequested = false
        capture = nil
        masterWriter = nil
        sourceWriters.removeAll(keepingCapacity: true)
        transcriber = nil
        fixedTranscriptionService = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
        preferredEncounteredSourceDegradation = nil
        pendingSourceDegradationPersistence = nil
        sourceDegradationPersistenceInProgress = false
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        nextTranscriptionSampleOffset = 0
        totalSampleCount = 0
        bookmarkCount = 0
        finalActiveDuration = 0
        captureFailed = false
        captureHealthCode = nil
        captureHealthMonitors.removeAll(keepingCapacity: true)
        captureHealthPipelineFailed = false
        captureInterruptionFinalizationScheduled = false
        invalidateCaptureHealthMonitoring()
    }

    private func resetStrandedFinalizationBeforeNewStart() {
        guard stateMachine.state == .finalizing,
              capture == nil,
              masterWriter == nil,
              sourceWriters.isEmpty,
              transcriber == nil,
              timeline == nil,
              streamTask == nil,
              transcriptPersistenceTask == nil else {
            return
        }
        // The persisted meeting remains in `.finalizing` so recovery can
        // inspect its files. Only the coordinator's released session is reset.
        resetAfterFailedStart()
    }

    private func resetAfterSuccessfulStop() {
        stateMachine = RecordingStateMachine()
        meetingID = nil
        mode = nil
        speakerDiarizationRequested = false
        releaseActiveResources()
        bookmarkCount = 0
        finalActiveDuration = 0
        captureFailed = false
        captureHealthCode = nil
        captureHealthMonitors.removeAll(keepingCapacity: true)
        captureHealthPipelineFailed = false
        captureInterruptionFinalizationScheduled = false
        invalidateCaptureHealthMonitoring()
    }

    private func releaseActiveResources() {
        capture = nil
        masterWriter = nil
        sourceWriters.removeAll(keepingCapacity: true)
        transcriber = nil
        fixedTranscriptionService = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        nextTranscriptionSampleOffset = 0
        totalSampleCount = 0
        captureHealthMonitors.removeAll(keepingCapacity: true)
        invalidateCaptureHealthMonitoring()
    }
}

extension MeetingCoordinator: MeetingDeletionPreparing {}
