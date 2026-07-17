import Foundation

enum MeetingCoordinatorError: Error, Equatable, Sendable {
    case permissionDenied(Set<CapturePermission>)
    case sessionUnavailable
    case operationInProgress
    case capturePipelineFailed
    case transcriptPersistenceFailed
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
    private var writer: (any MeetingAudioWriting)?
    private var transcriber: (any MeetingTranscriptionQueueing)?
    private var timeline: ActiveRecordingTimeline?
    private var streamTask: Task<Void, Never>?
    private var transcriptPersistenceTask: Task<Bool, Never>?
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
        var newWriter: (any MeetingAudioWriting)?
        var newTranscriber: (any MeetingTranscriptionQueueing)?

        do {
            let startedAt = await dependencies.clock.now()
            let createdID = try await dependencies.repository.createMeeting(
                mode: mode,
                startedAt: startedAt
            )
            newMeetingID = createdID
            let createdWriter = try await dependencies.writerFactory.makeWriter(
                meetingID: createdID
            )
            newWriter = createdWriter
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
            writer = createdWriter
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
            if let newWriter {
                _ = try? await newWriter.finish()
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
              let writer,
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

        do {
            let task = streamTask
            await capture.stop()
            await task?.value
            _ = try await writer.finish()
            await enqueueRemainingTranscriptionSamples(using: transcriber)
            await transcriber.drain()
            await transcriber.finishUpdates()
            if let transcriptPersistenceTask,
               !(await transcriptPersistenceTask.value) {
                throw MeetingCoordinatorError.transcriptPersistenceFailed
            }

            let endedAt = await dependencies.clock.now()
            try await dependencies.repository.finalizeMeeting(
                meetingID: meetingID,
                endedAt: endedAt,
                activeDuration: activeDuration
            )
            var readyMachine = stateMachine
            try readyMachine.send(.finalized)
            stateMachine = readyMachine
            resetAfterSuccessfulStop()
        } catch {
            finalActiveDuration = activeDuration
            await transcriber.drain()
            await transcriber.finishUpdates()
            _ = await transcriptPersistenceTask?.value
            releaseActiveResources()
            throw error
        }
    }

    private func makeStreamTask(
        _ stream: AsyncThrowingStream<CapturedAudioFrame, Error>
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await frame in stream {
                    try await self?.consume(frame)
                }
            } catch {
                await self?.handleCaptureFailure()
            }
        }
    }

    private func consume(_ frame: CapturedAudioFrame) async throws {
        guard let writer, let transcriber else {
            return
        }
        let normalizedFrame = CapturedAudioFrame(
            timestamp: Double(totalSampleCount)
                / AudioSegmentManifest.transcriptionSampleRate,
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            samples: frame.samples
        )
        try await writer.append(normalizedFrame)
        totalSampleCount += frame.samples.count
        pendingTranscriptionSamples.append(contentsOf: frame.samples)

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
        writer = nil
        transcriber = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
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
              writer == nil,
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
        writer = nil
        transcriber = nil
        timeline = nil
        streamTask = nil
        transcriptPersistenceTask = nil
        pendingTranscriptionSamples.removeAll(keepingCapacity: true)
        nextTranscriptionSampleOffset = 0
        totalSampleCount = 0
    }
}
