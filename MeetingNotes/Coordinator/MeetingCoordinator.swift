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

    var errorCode: String {
        switch self {
        case let .appendFailed(track):
            "source_track_write_failed_\(track.rawValue)"
        case let .finishFailed(track):
            "source_track_finish_failed_\(track.rawValue)"
        }
    }
}

struct MeetingCoordinatorSnapshot: Equatable, Sendable {
    let state: RecordingState
    let meetingID: UUID?
    let mode: MeetingMode?
    let activeTime: TimeInterval
    let bookmarkCount: Int
    let captureFailed: Bool
}

actor MeetingCoordinator {
    static let productionTranscriptionChunkSampleCount =
        10 * Int(AudioSegmentManifest.transcriptionSampleRate)

    private let dependencies: MeetingCoordinatorDependencies
    private let transcriptionChunkSampleCount: Int
    private var stateMachine = RecordingStateMachine()
    private var meetingID: UUID?
    private var mode: MeetingMode?
    private var capture: (any AudioCaptureSource)?
    private var masterWriter: (any MeetingAudioWriting)?
    private var sourceWriters: [AudioTrack: any MeetingAudioWriting] = [:]
    private var transcriber: (any MeetingTranscriptionQueueing)?
    private var timeline: ActiveRecordingTimeline?
    private var streamTask: Task<Void, Never>?
    private var transcriptPersistenceTask: Task<Bool, Never>?
    private var pendingSourceDegradations: [SourceDegradationReason] = []
    private var pendingTranscriptionSamples: [Float] = []
    private var nextTranscriptionSampleOffset = 0
    private var totalSampleCount = 0
    private var bookmarkCount = 0
    private var finalActiveDuration: TimeInterval = 0
    private var captureFailed = false
    private var lifecycleOperationInProgress = false

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
            captureFailed: captureFailed
        )
    }

    func canDeleteMeeting(id: UUID) -> Bool {
        guard meetingID == id else {
            return true
        }
        return !lifecycleOperationInProgress
            && capture == nil
            && masterWriter == nil
            && sourceWriters.isEmpty
            && transcriber == nil
            && timeline == nil
            && streamTask == nil
            && transcriptPersistenceTask == nil
    }

    @discardableResult
    func start(mode: MeetingMode) async throws -> UUID {
        try beginLifecycleOperation()
        defer { lifecycleOperationInProgress = false }
        resetStrandedFinalizationBeforeNewStart()
        var preparingMachine = stateMachine
        try preparingMachine.send(.prepare)
        stateMachine = preparingMachine

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
            let startedAt = await dependencies.clock.now()
            let speakerDiarizationRequested = await dependencies
                .speakerDiarizationPreference
                .isSpeakerDiarizationEnabled()
            let createdID = try await dependencies.repository.createMeeting(
                mode: mode,
                startedAt: startedAt,
                speakerDiarizationRequested: speakerDiarizationRequested
            )
            newMeetingID = createdID
            let writerSampleRate = PCMConverter.playbackSampleRate
            let createdMasterWriter = try await dependencies.writerFactory.makeWriter(
                meetingID: createdID,
                track: .master,
                sampleRate: writerSampleRate
            )
            newMasterWriter = createdMasterWriter
            if mode == .online {
                for track in [AudioTrack.microphone, .system] {
                    newSourceWriters[track] = try await dependencies.writerFactory
                        .makeWriter(
                            meetingID: createdID,
                            track: track,
                            sampleRate: writerSampleRate
                        )
                }
            }
            let createdTranscriber = try await dependencies.transcriptionFactory
                .makeQueue()
            newTranscriber = createdTranscriber
            let createdCapture = try await dependencies.captureFactory
                .makeCapture(for: mode)
            newCapture = createdCapture
            let stream = try await createdCapture.start()
            let timelineStart = await dependencies.clock.monotonicNow()

            var recordingMachine = stateMachine
            try recordingMachine.send(.start)
            try await dependencies.repository.updateState(
                meetingID: createdID,
                state: .recording
            )

            meetingID = createdID
            self.mode = mode
            capture = createdCapture
            masterWriter = createdMasterWriter
            sourceWriters = newSourceWriters
            transcriber = createdTranscriber
            timeline = ActiveRecordingTimeline(startedAt: timelineStart)
            stateMachine = recordingMachine
            bookmarkCount = 0
            finalActiveDuration = 0
            captureFailed = false
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
            await dependencies.panel.show()
            return createdID
        } catch {
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
                await newTranscriber.drain()
                await newTranscriber.finishUpdates()
            }
            if let newMeetingID {
                try? await dependencies.repository.deleteMeeting(
                    meetingID: newMeetingID
                )
            }
            resetAfterFailedStart()
            throw error
        }
    }

    func pauseOrResume() async throws {
        try beginLifecycleOperation()
        defer { lifecycleOperationInProgress = false }
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

        case .paused:
            var recordingMachine = stateMachine
            var recordingTimeline = timeline
            try recordingMachine.send(.resume)
            try recordingTimeline.resume(at: now)
            try await capture.resume()
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

        default:
            var invalidMachine = stateMachine
            try invalidMachine.send(.pause)
        }
    }

    func bookmark() async throws {
        try beginLifecycleOperation()
        defer { lifecycleOperationInProgress = false }
        guard let meetingID, let timeline else {
            throw MeetingCoordinatorError.sessionUnavailable
        }
        var bookmarkedMachine = stateMachine
        try bookmarkedMachine.send(.bookmark)
        let timestamp = timeline.activeTime(
            at: await dependencies.clock.monotonicNow()
        )
        try await dependencies.repository.appendBookmark(
            meetingID: meetingID,
            timestamp: timestamp
        )
        stateMachine = bookmarkedMachine
        bookmarkCount += 1
    }

    func stop() async throws {
        try beginLifecycleOperation()
        defer { lifecycleOperationInProgress = false }
        var finalizingMachine = stateMachine
        try finalizingMachine.send(.stop)
        guard let meetingID,
              let capture,
              let masterWriter,
              let transcriber,
              let timeline else {
            throw MeetingCoordinatorError.sessionUnavailable
        }

        let stoppedAt = await dependencies.clock.monotonicNow()
        let activeDuration = timeline.activeTime(at: stoppedAt)
        try await dependencies.repository.updateState(
            meetingID: meetingID,
            state: .finalizing
        )
        stateMachine = finalizingMachine
        await dependencies.panel.hide()
        var transcriptionUpdatesFinished = false

        do {
            let task = streamTask
            await capture.stop()
            await task?.value
            await finishSurvivingSourceWriters(meetingID: meetingID)
            _ = try await masterWriter.finish()
            await enqueueRemainingTranscriptionSamples(using: transcriber)
            await transcriber.drain()
            await transcriber.finishUpdates()
            transcriptionUpdatesFinished = true
            if let transcriptPersistenceTask,
               !(await transcriptPersistenceTask.value) {
                throw MeetingCoordinatorError.transcriptPersistenceFailed
            }

            let endedAt = await dependencies.clock.now()
            try await dependencies.repository.finalizeMeeting(
                meetingID: meetingID,
                endedAt: endedAt,
                activeDuration: activeDuration,
                sourceDegradationErrorCode:
                    pendingSourceDegradations.first?.errorCode
            )
            pendingSourceDegradations.removeAll(keepingCapacity: true)
            var readyMachine = stateMachine
            try readyMachine.send(.finalized)
            stateMachine = readyMachine
            resetAfterSuccessfulStop()
        } catch {
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
                await self?.handleCaptureFailure()
            }
        }
    }

    private func consume(_ packet: CapturedAudioPacket) async throws {
        guard let masterWriter, let transcriber else {
            return
        }
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
        if !pendingSourceDegradations.contains(reason) {
            pendingSourceDegradations.append(reason)
        }
        try? await persistPendingSourceDegradations(meetingID: meetingID)
    }

    private func persistPendingSourceDegradations(
        meetingID: UUID
    ) async throws {
        while let reason = pendingSourceDegradations.first {
            try await dependencies.repository.markSpeakerProcessingDegraded(
                meetingID: meetingID,
                errorCode: reason.errorCode
            )
            pendingSourceDegradations.removeFirst()
        }
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

    private func handleCaptureFailure() async {
        captureFailed = true
        if let capture {
            await capture.stop()
        }
    }

    private func beginLifecycleOperation() throws {
        guard !lifecycleOperationInProgress else {
            throw MeetingCoordinatorError.operationInProgress
        }
        lifecycleOperationInProgress = true
    }

    private func resetAfterFailedStart() {
        stateMachine = RecordingStateMachine()
        meetingID = nil
        mode = nil
        capture = nil
        masterWriter = nil
        sourceWriters.removeAll(keepingCapacity: true)
        transcriber = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
        pendingSourceDegradations.removeAll(keepingCapacity: true)
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        nextTranscriptionSampleOffset = 0
        totalSampleCount = 0
        bookmarkCount = 0
        finalActiveDuration = 0
        captureFailed = false
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
        releaseActiveResources()
        bookmarkCount = 0
        finalActiveDuration = 0
        captureFailed = false
    }

    private func releaseActiveResources() {
        capture = nil
        masterWriter = nil
        sourceWriters.removeAll(keepingCapacity: true)
        transcriber = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        nextTranscriptionSampleOffset = 0
        totalSampleCount = 0
    }
}

extension MeetingCoordinator: MeetingDeletionGuarding {}
