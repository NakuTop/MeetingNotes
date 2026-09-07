import XCTest
@testable import MeetingNotes

final class MeetingCoordinatorTests: XCTestCase {
    func testUnexpectedCaptureFailureFinalizesSavedContentAndReportsUser()
        async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            transcriptionChunkSampleCount: 1,
            transcriberEmitsDrafts: true,
            speakerDiarizationEnabled: true
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setDate(Date(timeIntervalSince1970: 1_005))
        await fixture.clock.setMonotonic(105)

        await fixture.capture.failStream()
        for _ in 0..<1_000 {
            if await fixture.interruptionReporter.meetingIDs().count == 1 {
                break
            }
            await Task.yield()
        }

        let recordedInterruption =
            await fixture.repository.interruptionFinalization()
        let interruption = try XCTUnwrap(recordedInterruption)
        let masterFinishCount =
            await fixture.writer(for: .master).finishCallCount()
        let microphoneFinishCount =
            await fixture.writer(for: .microphone).finishCallCount()
        let systemFinishCount =
            await fixture.writer(for: .system).finishCallCount()
        let reportedMeetingIDs =
            await fixture.interruptionReporter.meetingIDs()
        let presentationEvents =
            await fixture.recordingPresentation.events()
        let persistedState =
            await fixture.repository.savedState(for: meetingID)
        XCTAssertEqual(interruption.meetingID, meetingID)
        XCTAssertEqual(interruption.endedAt, Date(timeIntervalSince1970: 1_005))
        XCTAssertEqual(interruption.activeDuration, 5, accuracy: 0.001)
        XCTAssertEqual(interruption.lastErrorCode, "capture_interrupted")
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
        XCTAssertEqual(reportedMeetingIDs, [meetingID])
        XCTAssertEqual(
            presentationEvents,
            [
                .start(meetingID: meetingID, monotonicTime: 100),
                .finish(meetingID: meetingID, activeDuration: 5),
            ]
        )
        XCTAssertEqual(persistedState, .ready)
        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
    }

    func testFinalizationReusesServiceCapturedByQueue() async throws {
        let fixedService = FixedCoordinatorTranscriptionService(
            marker: "balanced-fixed-service"
        )
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            transcriptionChunkSampleCount: 1,
            fixedTranscriptionService: fixedService,
            speakerFinalizationOutcome: .unchanged
        )

        _ = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()

        let markers = await fixture.speakerFinalizer
            .recordedFixedServiceMarkers()
        XCTAssertEqual(markers, ["balanced-fixed-service"])
    }

    func testStartSnapshotsSpeakerDiarizationPreferenceForCreatedMeeting() async throws {
        let fixture = makeFixture(speakerDiarizationEnabled: true)

        let meetingID = try await fixture.coordinator.start(mode: .online)
        fixture.speakerDiarizationPreference.isEnabled = false
        let savedMeetings = await fixture.repository.savedMeetings()

        let savedMeeting = try XCTUnwrap(
            savedMeetings.first {
                $0.id == meetingID
            }
        )
        XCTAssertTrue(savedMeeting.speakerDiarizationRequested)
    }

    func testSpeakerProgressWriteFailureDoesNotBlockFinalization()
        async throws {
        let fixture = makeFixture(
            repositoryFailsSpeakerProcessingStart: true,
            speakerDiarizationEnabled: true
        )

        let meetingID = try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()
        let startAttempts = await fixture.repository
            .speakerProcessingStartAttemptCount()
        let savedState = await fixture.repository.savedState(
            for: meetingID
        )
        let finalization = await fixture.repository.finalization()

        XCTAssertEqual(startAttempts, 1)
        XCTAssertEqual(savedState, .ready)
        XCTAssertNotNil(finalization)
    }

    func testDisabledPreferenceDoesNotAttemptSpeakerProgressWrite()
        async throws {
        let fixture = makeFixture(speakerDiarizationEnabled: false)

        _ = try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()
        let startAttempts = await fixture.repository
            .speakerProcessingStartAttemptCount()

        XCTAssertEqual(startAttempts, 0)
    }

    @MainActor
    func testRequestedSpeakerProcessingUsesRealRepositoryLifecycle()
        async throws {
        let fixture = try makeRealRepositoryFixture(
            speakerDiarizationEnabled: true,
            speakerFinalizationOutcome: .unchanged
        )

        let meetingID = try await fixture.coordinator.start(mode: .online)
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID)
                .speakerProcessingState,
            .pending
        )

        try await fixture.coordinator.stop()

        XCTAssertEqual(
            fixture.speakerFinalizer.observedStates,
            [.processing]
        )
        let finalized = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(finalized.speakerProcessingState, .completed)
        XCTAssertNil(finalized.speakerProcessingErrorCode)
    }

    @MainActor
    func testDisabledSpeakerPreferenceNeverEntersProcessing()
        async throws {
        let fixture = try makeRealRepositoryFixture(
            speakerDiarizationEnabled: false,
            speakerFinalizationOutcome: .unchanged
        )

        let meetingID = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()

        XCTAssertEqual(
            fixture.speakerFinalizer.observedStates,
            [.notRequested]
        )
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID)
                .speakerProcessingState,
            .notRequested
        )
    }

    @MainActor
    func testRequestedDegradedOutcomeRemainsDegradedInRealRepository()
        async throws {
        let fixture = try makeRealRepositoryFixture(
            speakerDiarizationEnabled: true,
            speakerFinalizationOutcome: .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "speaker_diarization_inference_failed"
            )
        )

        let meetingID = try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()

        XCTAssertEqual(
            fixture.speakerFinalizer.observedStates,
            [.processing]
        )
        let finalized = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(finalized.speakerProcessingState, .degraded)
        XCTAssertEqual(
            finalized.speakerProcessingErrorCode,
            "speaker_diarization_inference_failed"
        )
    }

    func testOnlineMeetingCreatesOneWriterPerTrackAtPlaybackSampleRate() async throws {
        let fixture = makeFixture()

        try await fixture.coordinator.start(mode: .online)

        let requests = await fixture.writerRequests.values()
        XCTAssertEqual(
            requests.map(\.track),
            [.master, .microphone, .system]
        )
        XCTAssertEqual(
            requests.map(\.sampleRate),
            Array(repeating: PCMConverter.playbackSampleRate, count: 3)
        )
        XCTAssertEqual(
            Set(requests.map { "\($0.meetingID.uuidString):\($0.track.rawValue)" })
                .count,
            3
        )
    }

    func testOfflineMeetingCreatesOnlyMasterWriterAtPlaybackSampleRate() async throws {
        let fixture = makeFixture()

        try await fixture.coordinator.start(mode: .offline)

        let requests = await fixture.writerRequests.values()
        XCTAssertEqual(requests.map(\.track), [.master])
        XCTAssertEqual(
            requests.map(\.sampleRate),
            [PCMConverter.playbackSampleRate]
        )
    }

    func testMicrophoneMustBeAuthorizedBeforeRecording() async throws {
        let fixture = makeFixture(
            permissions: [
                .microphone: .denied,
                .screenRecording: .authorized
            ]
        )

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected denied microphone permission")
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .permissionDenied([.microphone])
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let events = await fixture.events.values()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertTrue(events.isEmpty)
    }

    func testUnavailableMicrophonePermissionPreventsRecordingFromStarting() async throws {
        let fixture = makeFixture(
            permissions: [
                .microphone: .unavailable,
                .screenRecording: .authorized
            ]
        )

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected unavailable microphone permission")
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .permissionDenied([.microphone])
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let events = await fixture.events.values()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertTrue(events.isEmpty)
    }

    func testPendingTranscriptionModelDoesNotCreateOrLockMeeting()
        async throws {
        let fixture = makeFixture(
            blockingTranscriptionFactoryOutcome: .success
        )
        let factory = try XCTUnwrap(
            fixture.blockingTranscriptionFactory
        )
        let entrySignal = try XCTUnwrap(
            fixture.transcriptionFactoryEntrySignal
        )
        let startCompletion = CoordinatorTestSignal(
            description: "meeting start completes"
        )
        let startTask = Task {
            defer { startCompletion.signal() }
            return try await fixture.coordinator.start(mode: .offline)
        }
        await fulfillment(of: [entrySignal.expectation], timeout: 0.5)
        guard entrySignal.count == 1 else {
            startTask.cancel()
            await factory.release()
            await fulfillment(
                of: [startCompletion.expectation],
                timeout: 0.5
            )
            if startCompletion.count == 1,
               case .success = await startTask.result {
                try? await fixture.coordinator.stop()
            }
            return
        }

        let pendingSnapshot = await fixture.coordinator.snapshot()
        let pendingMeetingIDs = await fixture.repository.createdMeetingIDs()
        let pendingWriterRequests = await fixture.writerRequests.values()
        let pendingCaptureModes = await fixture.captureModes.values()
        let pendingPanelCalls = await fixture.panel.calls()
        let pendingPresentationEvents =
            await fixture.recordingPresentation.events()

        XCTAssertEqual(pendingSnapshot.state, .idle)
        XCTAssertNil(pendingSnapshot.meetingID)
        XCTAssertFalse(pendingSnapshot.state.blocksCaptureSettingsChanges)
        XCTAssertTrue(pendingMeetingIDs.isEmpty)
        XCTAssertTrue(pendingWriterRequests.isEmpty)
        XCTAssertTrue(pendingCaptureModes.isEmpty)
        XCTAssertTrue(pendingPanelCalls.isEmpty)
        XCTAssertTrue(pendingPresentationEvents.isEmpty)

        await factory.release()
        let meetingID = try await startTask.value

        let startedSnapshot = await fixture.coordinator.snapshot()
        let startedMeetingIDs = await fixture.repository.createdMeetingIDs()
        let startedWriterRequests = await fixture.writerRequests.values()
        let startedCaptureModes = await fixture.captureModes.values()
        let startedPanelCalls = await fixture.panel.calls()
        XCTAssertEqual(entrySignal.count, 1)
        XCTAssertEqual(startedSnapshot.state, .recording)
        XCTAssertEqual(startedSnapshot.meetingID, meetingID)
        XCTAssertEqual(startedMeetingIDs, [meetingID])
        XCTAssertEqual(startedWriterRequests.map(\.track), [.master])
        XCTAssertEqual(startedCaptureModes, [.offline])
        XCTAssertEqual(startedPanelCalls, ["show"])

        try await fixture.coordinator.stop()
    }

    func testSecondStartWhileRecordingPreservesOriginalSession()
        async throws {
        let fixture = makeFixture()
        let originalMeetingID = try await fixture.coordinator.start(
            mode: .offline
        )

        do {
            _ = try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected duplicate start to fail")
        } catch {
            XCTAssertEqual(
                error as? RecordingStateError,
                .invalidTransition(.recording, .prepare)
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let savedState = await fixture.repository.savedState(
            for: originalMeetingID
        )
        let panelCalls = await fixture.panel.calls()
        let events = await fixture.events.values()
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(snapshot.meetingID, originalMeetingID)
        XCTAssertEqual(snapshot.mode, .offline)
        XCTAssertEqual(savedState, .recording)
        XCTAssertEqual(panelCalls, ["show"])
        XCTAssertFalse(events.contains("capture.stop"))

        do {
            try await fixture.coordinator.stop()
        } catch {
            XCTFail("Original meeting must remain stoppable: \(error)")
            await fixture.capture.stop()
            await fixture.panel.hide()
        }
    }

    func testTranscriptionModelFailureBeforeMeetingCreationLeavesNoMeeting()
        async throws {
        let fixture = makeFixture(
            blockingTranscriptionFactoryOutcome: .failure
        )
        let factory = try XCTUnwrap(
            fixture.blockingTranscriptionFactory
        )
        let entrySignal = try XCTUnwrap(
            fixture.transcriptionFactoryEntrySignal
        )
        let startCompletion = CoordinatorTestSignal(
            description: "failed meeting start completes"
        )
        let startTask = Task {
            defer { startCompletion.signal() }
            return try await fixture.coordinator.start(mode: .offline)
        }
        await fulfillment(of: [entrySignal.expectation], timeout: 0.5)
        guard entrySignal.count == 1 else {
            startTask.cancel()
            await factory.release()
            await fulfillment(
                of: [startCompletion.expectation],
                timeout: 0.5
            )
            if startCompletion.count == 1,
               case .success = await startTask.result {
                try? await fixture.coordinator.stop()
            }
            return
        }
        await factory.release()

        do {
            _ = try await startTask.value
            XCTFail("Expected transcription model preparation failure")
            try? await fixture.coordinator.stop()
        } catch {
            XCTAssertEqual(
                error as? CoordinatorTestError,
                .transcriptionFactory
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let createdMeetingIDs = await fixture.repository.createdMeetingIDs()
        let writerRequests = await fixture.writerRequests.values()
        let captureModes = await fixture.captureModes.values()
        let panelCalls = await fixture.panel.calls()
        let presentationEvents =
            await fixture.recordingPresentation.events()
        XCTAssertEqual(entrySignal.count, 1)
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertFalse(snapshot.state.blocksCaptureSettingsChanges)
        XCTAssertTrue(createdMeetingIDs.isEmpty)
        XCTAssertTrue(writerRequests.isEmpty)
        XCTAssertTrue(captureModes.isEmpty)
        XCTAssertTrue(panelCalls.isEmpty)
        XCTAssertTrue(presentationEvents.isEmpty)
    }

    func testDeniedPermissionDoesNotPrepareTranscriptionModelOrCreateMeeting()
        async throws {
        let fixture = makeFixture(
            permissions: [
                .microphone: .denied,
                .screenRecording: .authorized
            ],
            blockingTranscriptionFactoryOutcome: .success
        )
        let factory = try XCTUnwrap(
            fixture.blockingTranscriptionFactory
        )
        let entrySignal = try XCTUnwrap(
            fixture.transcriptionFactoryEntrySignal
        )
        await factory.release()

        do {
            _ = try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected denied microphone permission")
            try? await fixture.coordinator.stop()
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .permissionDenied([.microphone])
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let createdMeetingIDs = await fixture.repository.createdMeetingIDs()
        let writerRequests = await fixture.writerRequests.values()
        let captureModes = await fixture.captureModes.values()
        let panelCalls = await fixture.panel.calls()
        XCTAssertEqual(entrySignal.count, 0)
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertFalse(snapshot.state.blocksCaptureSettingsChanges)
        XCTAssertTrue(createdMeetingIDs.isEmpty)
        XCTAssertTrue(writerRequests.isEmpty)
        XCTAssertTrue(captureModes.isEmpty)
        XCTAssertTrue(panelCalls.isEmpty)
    }

    func testCallerCancellationAfterModelReadyBeforeMeetingCreationLeavesIdle()
        async throws {
        let fixture = makeFixture(
            blockingTranscriptionFactoryOutcome: .success,
            clockSuspendsNextDateRead: true
        )
        let factory = try XCTUnwrap(
            fixture.blockingTranscriptionFactory
        )
        let factoryEntrySignal = try XCTUnwrap(
            fixture.transcriptionFactoryEntrySignal
        )
        let clockEntrySignal = try XCTUnwrap(
            fixture.clock.dateReadEntrySignal
        )
        let startCompletion = CoordinatorTestSignal(
            description: "cancelled pre-creation start completes"
        )
        let startTask = Task {
            defer { startCompletion.signal() }
            return try await fixture.coordinator.start(mode: .offline)
        }

        await fulfillment(
            of: [factoryEntrySignal.expectation],
            timeout: 0.5
        )
        await factory.release()
        await fulfillment(of: [clockEntrySignal.expectation], timeout: 0.5)
        startTask.cancel()
        await fixture.clock.releaseDateRead()
        await fulfillment(of: [startCompletion.expectation], timeout: 0.5)

        guard startCompletion.count == 1 else { return }
        switch await startTask.result {
        case .success:
            XCTFail("Expected caller cancellation")
            try? await fixture.coordinator.stop()
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }

        let snapshot = await fixture.coordinator.snapshot()
        let createdMeetingIDs = await fixture.repository.createdMeetingIDs()
        let savedMeetings = await fixture.repository.savedMeetings()
        let writerRequests = await fixture.writerRequests.values()
        let captureModes = await fixture.captureModes.values()
        let panelCalls = await fixture.panel.calls()
        let presentationEvents =
            await fixture.recordingPresentation.events()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertTrue(createdMeetingIDs.isEmpty)
        XCTAssertTrue(savedMeetings.isEmpty)
        XCTAssertTrue(writerRequests.isEmpty)
        XCTAssertTrue(captureModes.isEmpty)
        XCTAssertTrue(panelCalls.isEmpty)
        XCTAssertTrue(presentationEvents.isEmpty)
    }

    func testCallerCancellationDuringRepositoryCreationRollsBackMeeting()
        async throws {
        let fixture = makeFixture(repositorySuspendsCreateMeeting: true)
        let repositoryEntrySignal = try XCTUnwrap(
            fixture.repository.createMeetingEntrySignal
        )
        let startCompletion = CoordinatorTestSignal(
            description: "cancelled repository start completes"
        )
        let startTask = Task {
            defer { startCompletion.signal() }
            return try await fixture.coordinator.start(mode: .offline)
        }

        await fulfillment(
            of: [repositoryEntrySignal.expectation],
            timeout: 0.5
        )
        startTask.cancel()
        await fixture.repository.releaseCreateMeeting()
        await fulfillment(of: [startCompletion.expectation], timeout: 0.5)

        guard startCompletion.count == 1 else { return }
        switch await startTask.result {
        case .success:
            XCTFail("Expected caller cancellation")
            try? await fixture.coordinator.stop()
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }

        let snapshot = await fixture.coordinator.snapshot()
        let createdMeetingIDs = await fixture.repository.createdMeetingIDs()
        let savedMeetings = await fixture.repository.savedMeetings()
        let writerRequests = await fixture.writerRequests.values()
        let captureModes = await fixture.captureModes.values()
        let panelCalls = await fixture.panel.calls()
        let presentationEvents =
            await fixture.recordingPresentation.events()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(createdMeetingIDs.count, 1)
        XCTAssertTrue(savedMeetings.isEmpty)
        XCTAssertTrue(writerRequests.isEmpty)
        XCTAssertTrue(captureModes.isEmpty)
        XCTAssertTrue(panelCalls.isEmpty)
        XCTAssertTrue(presentationEvents.isEmpty)
    }

    func testStartFailureRollsBackAndClosesStartedResources() async throws {
        let fixture = makeFixture(captureFailsToStart: true)

        do {
            try await fixture.coordinator.start(mode: .offline)
            XCTFail("Expected capture start failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .captureStart)
        }

        let snapshot = await fixture.coordinator.snapshot()
        let events = await fixture.events.values()
        let presentationEvents = await fixture.recordingPresentation.events()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(presentationEvents.isEmpty)
        XCTAssertEqual(
            events,
            [
                "repository.create",
                "capture.start",
                "capture.stop",
                "writer.finish",
                "transcriber.drain",
                "transcriber.finishUpdates",
                "repository.delete"
            ]
        )
    }

    func testOnlineStartFailureFinishesEveryCreatedWriterExactlyOnce() async throws {
        let fixture = makeFixture(captureFailsToStart: true)

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected capture start failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .captureStart)
        }

        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testOnlineWriterCreationFailureFinishesOnlyCreatedWritersOnce() async throws {
        let fixture = makeFixture(writerFactoryFailsForTrack: .system)

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected system writer creation failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .writerFactory)
        }

        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 0)
    }

    func testPauseResumeAndBookmarkUseOnlyActiveTimeWithoutPanelMutation() async throws {
        let fixture = makeFixture()
        let startedMeetingID = try await fixture.coordinator.start(
            mode: .offline
        )
        let startedSnapshot = await fixture.coordinator.snapshot()
        XCTAssertEqual(startedMeetingID, startedSnapshot.meetingID)

        await fixture.clock.setMonotonic(110)
        try await fixture.coordinator.pauseOrResume()
        await fixture.clock.setMonotonic(130)
        try await fixture.coordinator.bookmark()

        var snapshot = await fixture.coordinator.snapshot()
        var bookmarks = await fixture.repository.savedBookmarks()
        var panelCalls = await fixture.panel.calls()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.activeTime, 10, accuracy: 0.001)
        XCTAssertEqual(bookmarks, [10])
        XCTAssertEqual(panelCalls, ["show"])

        await fixture.clock.setMonotonic(140)
        try await fixture.coordinator.pauseOrResume()
        await fixture.clock.setMonotonic(145)
        try await fixture.coordinator.bookmark()

        snapshot = await fixture.coordinator.snapshot()
        bookmarks = await fixture.repository.savedBookmarks()
        panelCalls = await fixture.panel.calls()
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(snapshot.activeTime, 15, accuracy: 0.001)
        XCTAssertEqual(bookmarks, [10, 15])
        XCTAssertEqual(panelCalls, ["show"])
    }

    func testRecordingPresentationTracksExactPauseResumeAndStopTimeline() async throws {
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [0.2],
            transcriptionSamples: [0.2],
            transcriptionSampleRate:
                AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(frames: [frame])
        let meetingID = try await fixture.coordinator.start(mode: .offline)
        await waitForMasterFrames(1, fixture: fixture)

        await fixture.clock.setMonotonic(105)
        try await fixture.coordinator.pauseOrResume()
        await fixture.clock.setMonotonic(205)
        try await fixture.coordinator.pauseOrResume()
        await fixture.clock.setMonotonic(208)
        try await fixture.coordinator.stop()

        let events = await fixture.recordingPresentation.events()
        XCTAssertEqual(
            events,
            [
                .start(meetingID: meetingID, monotonicTime: 100),
                .pause(meetingID: meetingID, activeDuration: 5),
                .resume(
                    meetingID: meetingID,
                    activeDuration: 5,
                    monotonicTime: 205
                ),
                .finish(meetingID: meetingID, activeDuration: 8)
            ]
        )
    }

    func testStopUsesSafeOrderAndRejectsDuplicateLifecycleCommands() async throws {
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [0.2],
            transcriptionSamples: [0.2],
            transcriptionSampleRate:
                AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(frames: [frame])
        let meetingID = try await fixture.coordinator.start(mode: .offline)
        await waitForMasterFrames(1, fixture: fixture)

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected duplicate start to fail")
        } catch {
            XCTAssertEqual(
                error as? RecordingStateError,
                .invalidTransition(.recording, .prepare)
            )
        }

        await fixture.events.removeAll()
        await fixture.clock.setMonotonic(125)
        await fixture.clock.setDate(Date(timeIntervalSince1970: 1_025))
        try await fixture.coordinator.stop()

        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        let savedFinalization = await fixture.repository.finalization()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let finalization = try XCTUnwrap(savedFinalization)
        XCTAssertEqual(
            events,
            [
                "repository.finalizing",
                "panel.hide",
                "capture.stop",
                "writer.finish",
                "transcriber.drain",
                "transcriber.finishUpdates",
                "repository.finalize.attempt",
                "repository.finalize"
            ]
        )
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertNil(snapshot.mode)
        XCTAssertEqual(snapshot.activeTime, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.bookmarkCount, 0)
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(persistedState, .ready)
        XCTAssertEqual(finalization.activeDuration, 25, accuracy: 0.001)
        XCTAssertEqual(
            finalization.endedAt,
            Date(timeIntervalSince1970: 1_025)
        )

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected duplicate stop to fail")
        } catch {
            XCTAssertEqual(
                error as? RecordingStateError,
                .invalidTransition(.idle, .stop)
            )
        }
    }

    func testStopReplacesOnlineTranscriptAfterWritersAndProvisionalPersistence()
        async throws {
        let replacement = [
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 0,
                    endTime: 1,
                    text: "我"
                ),
                speakerID: "me",
                source: .microphone
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 2,
                    text: "远端"
                ),
                speakerID: "remote",
                source: .system
            ),
        ]
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            transcriptionChunkSampleCount: 1,
            transcriberEmitsDrafts: true,
            speakerFinalizationOutcome: .replacement(
                replacement,
                sourceRevision: 1
            )
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)
        for _ in 0..<1_000 {
            if await fixture.repository.savedTranscripts().count == 1 {
                break
            }
            await Task.yield()
        }

        try await fixture.coordinator.stop()

        let events = await fixture.events.values()
        let finalizerRequests = await fixture.speakerFinalizer
            .recordedRequests()
        let request = try XCTUnwrap(
            finalizerRequests.first
        )
        let repositoryReplacement = await fixture.repository
            .savedReplacement()
        let savedReplacement = try XCTUnwrap(
            repositoryReplacement
        )
        XCTAssertEqual(request.meetingID, meetingID)
        XCTAssertEqual(request.mode, .online)
        XCTAssertFalse(request.diarizationRequested)
        XCTAssertEqual(request.provisional.map(\.text), ["chunk-0"])
        XCTAssertEqual(savedReplacement.drafts, replacement)
        XCTAssertEqual(savedReplacement.sourceRevision, 1)

        let microphoneFinished = try XCTUnwrap(
            events.firstIndex(of: "writer.microphone.finish")
        )
        let systemFinished = try XCTUnwrap(
            events.firstIndex(of: "writer.system.finish")
        )
        let masterFinished = try XCTUnwrap(
            events.firstIndex(of: "writer.finish")
        )
        let updatesFinished = try XCTUnwrap(
            events.firstIndex(of: "transcriber.finishUpdates")
        )
        let provisionalPersisted = try XCTUnwrap(
            events.firstIndex(of: "repository.transcript")
        )
        let speakerFinalized = try XCTUnwrap(
            events.firstIndex(of: "speaker.finalize")
        )
        let replacementSaved = try XCTUnwrap(
            events.firstIndex(of: "repository.replace")
        )
        let meetingFinalized = try XCTUnwrap(
            events.firstIndex(of: "repository.finalize")
        )
        XCTAssertLessThan(microphoneFinished, speakerFinalized)
        XCTAssertLessThan(systemFinished, speakerFinalized)
        XCTAssertLessThan(masterFinished, speakerFinalized)
        XCTAssertLessThan(updatesFinished, speakerFinalized)
        XCTAssertLessThan(provisionalPersisted, speakerFinalized)
        XCTAssertLessThan(speakerFinalized, replacementSaved)
        XCTAssertLessThan(replacementSaved, meetingFinalized)
    }

    func testDegradedFinalizationWithoutReplacementKeepsMeetingReady()
        async throws {
        let fixture = makeFixture(
            speakerFinalizationOutcome: .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "source_track_transcription_failed_system"
            )
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)

        try await fixture.coordinator.stop()

        let replacement = await fixture.repository.savedReplacement()
        let codes = await fixture.repository.savedDegradationCodes()
        let state = await fixture.repository.savedState(for: meetingID)
        XCTAssertNil(replacement)
        XCTAssertEqual(
            codes,
            ["source_track_transcription_failed_system"]
        )
        XCTAssertEqual(state, .ready)
    }

    func testDegradedCoarseReplacementUsesStartPreferenceSnapshot()
        async throws {
        let replacement = [
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 0,
                    endTime: 1,
                    text: "粗粒度"
                ),
                speakerID: "me",
                source: .microphone
            ),
        ]
        let fixture = makeFixture(
            speakerDiarizationEnabled: true,
            speakerFinalizationOutcome: .degraded(
                replacement: replacement,
                sourceRevision: 1,
                errorCode: "speaker_diarization_unavailable"
            )
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)
        fixture.speakerDiarizationPreference.isEnabled = false

        try await fixture.coordinator.stop()

        let finalizerRequests = await fixture.speakerFinalizer
            .recordedRequests()
        let request = try XCTUnwrap(
            finalizerRequests.first
        )
        let repositoryReplacement = await fixture.repository
            .savedReplacement()
        let savedReplacement = try XCTUnwrap(
            repositoryReplacement
        )
        let codes = await fixture.repository.savedDegradationCodes()
        let state = await fixture.repository.savedState(for: meetingID)
        XCTAssertTrue(request.diarizationRequested)
        XCTAssertEqual(savedReplacement.drafts, replacement)
        XCTAssertEqual(codes, ["speaker_diarization_unavailable"])
        XCTAssertEqual(state, .ready)
    }

    func testReplacementPersistenceFailureKeepsProvisionalMeetingReady()
        async throws {
        let fixture = makeFixture(
            repositoryFailsReplacement: true,
            speakerFinalizationOutcome: .replacement(
                [
                    AttributedTranscriptDraft(
                        transcript: TranscriptDraft(
                            startTime: 0,
                            endTime: 1,
                            text: "替换"
                        ),
                        speakerID: "me",
                        source: .microphone
                    ),
                ],
                sourceRevision: 1
            )
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)

        try await fixture.coordinator.stop()

        let replacement = await fixture.repository.savedReplacement()
        let codes = await fixture.repository.savedDegradationCodes()
        let state = await fixture.repository.savedState(for: meetingID)
        XCTAssertNil(replacement)
        XCTAssertEqual(codes, ["speaker_transcript_replacement_failed"])
        XCTAssertEqual(state, .ready)
    }

    func testStartsOfflineAgainAfterSuccessfulOfflineMeeting() async throws {
        let fixture = makeFixture()

        let firstID = try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()
        let secondID = try await fixture.coordinator.start(mode: .offline)
        let captureModes = await fixture.captureModes.values()
        let meetings = await fixture.repository.savedMeetings()

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(captureModes, [.offline, .offline])
        XCTAssertEqual(
            meetings,
            [
                .init(id: firstID, mode: .offline, state: .ready),
                .init(id: secondID, mode: .offline, state: .recording)
            ]
        )
    }

    func testStartsOnlineAfterSuccessfulOfflineMeeting() async throws {
        let fixture = makeFixture()

        let firstID = try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()
        let secondID = try await fixture.coordinator.start(mode: .online)
        let captureModes = await fixture.captureModes.values()
        let meetings = await fixture.repository.savedMeetings()

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(captureModes, [.offline, .online])
        XCTAssertEqual(
            meetings,
            [
                .init(id: firstID, mode: .offline, state: .ready),
                .init(id: secondID, mode: .online, state: .recording)
            ]
        )
    }

    func testStartsOfflineAfterSuccessfulOnlineMeeting() async throws {
        let fixture = makeFixture()

        let firstID = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()
        let secondID = try await fixture.coordinator.start(mode: .offline)
        let captureModes = await fixture.captureModes.values()
        let meetings = await fixture.repository.savedMeetings()

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(captureModes, [.online, .offline])
        XCTAssertEqual(
            meetings,
            [
                .init(id: firstID, mode: .online, state: .ready),
                .init(id: secondID, mode: .offline, state: .recording)
            ]
        )
    }

    func testManualStopRacingUnexpectedFailureFinalizesOnce() async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            writerFailsAppend: true
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.bookmark()
        for _ in 0..<100 {
            if await fixture.coordinator.snapshot().captureFailed {
                break
            }
            await Task.yield()
        }

        try await fixture.coordinator.stop()

        let snapshot = await fixture.coordinator.snapshot()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let interruptionFinalizationCount = await fixture.repository
            .interruptionFinalizationCount()
        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertNil(snapshot.mode)
        XCTAssertEqual(snapshot.activeTime, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.bookmarkCount, 0)
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(persistedState, .ready)
        XCTAssertEqual(interruptionFinalizationCount, 1)
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testRoutesNormalizedAudioToWriterAndFixedTranscriptionChunks() async throws {
        let transcriptionSamples: [Float] = [0, 1, 2, 3, 4, 5]
        let frame = CapturedAudioFrame(
            timestamp: 99,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: transcriptionSamples,
            transcriptionSamples: transcriptionSamples,
            transcriptionSampleRate: AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(frames: [frame], transcriptionChunkSampleCount: 4)

        try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()

        let written = await fixture.writer.writtenFrames()
        let chunks = await fixture.transcriber.chunks()
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].timestamp, 0, accuracy: 0.000_001)
        XCTAssertEqual(written[0].sampleRate, PCMConverter.playbackSampleRate)
        XCTAssertEqual(written[0].samples, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(chunks.map(\.samples), [[0, 1, 2, 3], [4, 5]])
        XCTAssertEqual(chunks.map(\.startingAt), [0, 4.0 / 16_000])
    }

    func testRoutes48kPlaybackSamplesAnd16kTranscriptionSamplesSeparately() async throws {
        let frame = CapturedAudioFrame(
            timestamp: 99,
            sampleRate: 48_000,
            samples: [1, 2, 3, 4, 5, 6],
            transcriptionSamples: [10, 11, 12, 13],
            transcriptionSampleRate: 16_000
        )
        let fixture = makeFixture(
            frames: [frame],
            transcriptionChunkSampleCount: 4
        )

        try await fixture.coordinator.start(mode: .offline)
        try await fixture.coordinator.stop()

        let written = await fixture.writer.writtenFrames()
        let chunks = await fixture.transcriber.chunks()
        XCTAssertEqual(written.first?.sampleRate, 48_000)
        XCTAssertEqual(written.first?.samples, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(chunks.map(\.samples), [[10, 11, 12, 13]])
    }

    func testRoutesOnlineMasterAndSourceFramesAtMasterTimelineTimestamps() async throws {
        let first = CapturedAudioPacket(
            master: CapturedAudioFrame(
                timestamp: 50,
                sampleRate: 48_000,
                samples: [1, 2, 3, 4],
                transcriptionSamples: [1, 2],
                transcriptionSampleRate: 16_000
            ),
            sourceFrames: [
                .microphone: CapturedAudioFrame(
                    timestamp: 51,
                    sampleRate: 48_000,
                    samples: [10, 11, 12, 13]
                ),
                .system: CapturedAudioFrame(
                    timestamp: 52,
                    sampleRate: 48_000,
                    samples: [20, 21, 22, 23]
                )
            ]
        )
        let second = CapturedAudioPacket(
            master: CapturedAudioFrame(
                timestamp: 60,
                sampleRate: 48_000,
                samples: [5, 6],
                transcriptionSamples: [3],
                transcriptionSampleRate: 16_000
            ),
            sourceFrames: [
                .microphone: CapturedAudioFrame(
                    timestamp: 61,
                    sampleRate: 48_000,
                    samples: [14, 15]
                ),
                .system: CapturedAudioFrame(
                    timestamp: 62,
                    sampleRate: 48_000,
                    samples: [24, 25]
                )
            ]
        )
        let fixture = makeFixture(
            packets: [first, second],
            transcriptionChunkSampleCount: 100
        )

        try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()

        let expectedTimestamps: [TimeInterval] = [0, 4.0 / 48_000]
        let master = await fixture.writer(for: .master).writtenFrames()
        let microphone = await fixture.writer(for: .microphone).writtenFrames()
        let system = await fixture.writer(for: .system).writtenFrames()
        XCTAssertEqual(master.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(microphone.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(system.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(master.map(\.samples), [[1, 2, 3, 4], [5, 6]])
        XCTAssertEqual(
            microphone.map(\.samples),
            [[10, 11, 12, 13], [14, 15]]
        )
        XCTAssertEqual(system.map(\.samples), [[20, 21, 22, 23], [24, 25]])
    }

    func testSourceAppendFailureDegradesOnlyThatTrackAndMasterKeepsWriting() async throws {
        let packets = [
            makeOnlinePacket(index: 0),
            makeOnlinePacket(index: 1)
        ]
        let fixture = makeFixture(
            packets: packets,
            writerFailsAppendTracks: [.microphone],
            writerFailsFinishTracks: [.microphone]
        )

        try await fixture.coordinator.start(mode: .online)
        for _ in 0..<1_000 {
            if await fixture.writer(for: .master).writtenFrames().count == 2 {
                break
            }
            await Task.yield()
        }

        let recordingSnapshot = await fixture.coordinator.snapshot()
        let degradationCodes = await fixture.repository.savedDegradationCodes()
        let masterSamples = await fixture.writer(for: .master)
            .writtenFrames()
            .map(\.samples)
        let microphoneAppendCount = await fixture.writer(for: .microphone)
            .appendCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemSamples = await fixture.writer(for: .system)
            .writtenFrames()
            .map(\.samples)
        XCTAssertFalse(recordingSnapshot.captureFailed)
        XCTAssertEqual(masterSamples, [[0], [1]])
        XCTAssertEqual(microphoneAppendCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemSamples, [[20], [21]])
        XCTAssertEqual(
            degradationCodes,
            ["source_track_write_failed_microphone"]
        )

        try await fixture.coordinator.stop()
        let finalMicrophoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        XCTAssertEqual(
            finalMicrophoneFinishCount,
            1,
            "Removed source writers must not be finished again during stop"
        )
    }

    func testNoMasterFramesAfterStartupDeadlineFinalizesAsInterrupted()
        async throws {
        let fixture = makeFixture()
        let meetingID = try await fixture.coordinator.start(mode: .offline)
        await fixture.clock.setMonotonic(105)

        fixture.healthScheduler.runNextCheck()
        for _ in 0..<100 {
            if await fixture.coordinator.snapshot().captureFailed {
                break
            }
            await Task.yield()
        }

        for _ in 0..<1_000 {
            if await fixture.interruptionReporter.meetingIDs().count == 1 {
                break
            }
            await Task.yield()
        }

        let snapshot = await fixture.coordinator.snapshot()
        let interruption = await fixture.repository.interruptionFinalization()
        let reportedMeetingIDs =
            await fixture.interruptionReporter.meetingIDs()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(interruption?.meetingID, meetingID)
        XCTAssertEqual(reportedMeetingIDs, [meetingID])
    }

    func testOnlineMicrophoneSilenceDegradesWithoutDiscardingHealthySystemTrack()
        async throws {
        let packet = makeHealthPacket(
            microphoneSamples: [0, 0],
            systemSamples: [0.3, -0.2]
        )
        let fixture = makeFixture(packets: [packet])
        _ = try await fixture.coordinator.start(mode: .online)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setMonotonic(106)

        fixture.healthScheduler.runNextCheck()
        await waitForHealthCode(
            .microphoneSustainedSilence,
            fixture: fixture
        )

        let snapshot = await fixture.coordinator.snapshot()
        let systemFrames = await fixture.writer(for: .system).writtenFrames()
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(systemFrames.map(\.samples), [[0.3, -0.2]])

        try await fixture.coordinator.stop()
        let savedFinalization = await fixture.repository.finalization()
        let finalization = try XCTUnwrap(savedFinalization)
        XCTAssertEqual(
            finalization.sourceDegradationErrorCode,
            "source_track_sustained_silence_microphone"
        )
    }

    func testOnlineSystemSilenceDegradesWithoutDiscardingHealthyMicrophoneTrack()
        async throws {
        let packet = makeHealthPacket(
            microphoneSamples: [0.25, -0.15],
            systemSamples: [0, 0]
        )
        let fixture = makeFixture(packets: [packet])
        _ = try await fixture.coordinator.start(mode: .online)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setMonotonic(106)

        fixture.healthScheduler.runNextCheck()
        await waitForHealthCode(.systemSustainedSilence, fixture: fixture)

        let snapshot = await fixture.coordinator.snapshot()
        let microphoneFrames = await fixture.writer(for: .microphone)
            .writtenFrames()
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(microphoneFrames.map(\.samples), [[0.25, -0.15]])

        try await fixture.coordinator.stop()
        let savedFinalization = await fixture.repository.finalization()
        let finalization = try XCTUnwrap(savedFinalization)
        XCTAssertEqual(
            finalization.sourceDegradationErrorCode,
            "source_track_sustained_silence_system"
        )
    }

    func testBothSilentOnlineSourcesFailCapturePipeline() async throws {
        let packet = makeHealthPacket(
            microphoneSamples: [0, 0],
            systemSamples: [0, 0]
        )
        let fixture = makeFixture(packets: [packet])
        _ = try await fixture.coordinator.start(mode: .online)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setMonotonic(106)

        fixture.healthScheduler.runNextCheck()
        await waitForHealthCode(.bothSourcesDegraded, fixture: fixture)

        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertTrue(snapshot.captureFailed)
        XCTAssertEqual(snapshot.captureHealthCode, .bothSourcesDegraded)
    }

    func testPausedWallClockTimeDoesNotConsumeFirstFrameDeadline()
        async throws {
        let fixture = makeFixture()
        _ = try await fixture.coordinator.start(mode: .offline)
        await fixture.clock.setMonotonic(104)
        try await fixture.coordinator.pauseOrResume()
        await fixture.clock.setMonotonic(1_000)

        fixture.healthScheduler.runNextCheck()
        for _ in 0..<100 {
            await Task.yield()
        }

        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertNil(snapshot.captureHealthCode)
        XCTAssertEqual(snapshot.activeTime, 4, accuracy: 0.001)
    }

    func testOfflineSustainedSilenceIsWarningRatherThanPipelineFailure()
        async throws {
        let silentFrame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [0, 0],
            transcriptionSamples: [0, 0],
            transcriptionSampleRate:
                AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(frames: [silentFrame])
        _ = try await fixture.coordinator.start(mode: .offline)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setMonotonic(106)

        fixture.healthScheduler.runNextCheck()
        await waitForHealthCode(.masterSustainedSilence, fixture: fixture)

        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(
            snapshot.captureHealthCode,
            .masterSustainedSilence
        )
        try await fixture.coordinator.stop()
    }

    func testWriterDegradationOutranksDerivedTranscriptionDegradationAtFinalization()
        async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            writerFailsAppendTracks: [.microphone],
            speakerFinalizationOutcome: .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "source_track_transcription_failed_system"
            )
        )

        _ = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()

        let savedFinalization = await fixture.repository.finalization()
        let finalization = try XCTUnwrap(savedFinalization)
        let degradationCodes = await fixture.repository
            .savedDegradationCodes()
        let degradationAttempts = await fixture.repository
            .degradationPersistenceAttemptCount()
        XCTAssertEqual(
            finalization.sourceDegradationErrorCode,
            "source_track_write_failed_microphone"
        )
        XCTAssertEqual(
            degradationCodes,
            ["source_track_write_failed_microphone"]
        )
        XCTAssertEqual(
            degradationAttempts,
            1,
            "Derived degradation must not overwrite a writer root cause"
        )
    }

    func testWriterDegradationPrecedenceIsStableByFailureClassAndTrack()
        async throws {
        let cases: [(
            append: Set<AudioTrack>,
            finish: Set<AudioTrack>,
            expected: String
        )] = [
            (
                append: [.system],
                finish: [.microphone],
                expected: "source_track_write_failed_system"
            ),
            (
                append: [],
                finish: [.system, .microphone],
                expected: "source_track_finish_failed_microphone"
            ),
        ]

        for testCase in cases {
            let fixture = makeFixture(
                packets: [makeOnlinePacket(index: 0)],
                writerFailsAppendTracks: testCase.append,
                writerFailsFinishTracks: testCase.finish
            )

            _ = try await fixture.coordinator.start(mode: .online)
            try await fixture.coordinator.stop()

            let savedFinalization = await fixture.repository.finalization()
            let finalization = try XCTUnwrap(savedFinalization)
            let degradationCodes = await fixture.repository
                .savedDegradationCodes()
            XCTAssertEqual(
                finalization.sourceDegradationErrorCode,
                testCase.expected
            )
            XCTAssertEqual(
                degradationCodes,
                [testCase.expected]
            )
        }
    }

    func testFinalizeFailureKeepsPreferredWriterDegradationDurable()
        async throws {
        let fixture = makeFixture(
            writerFailsFinishTracks: [.microphone, .system],
            repositoryFailsFinalize: true
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected repository finalize failure")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorTestError,
                .repositoryFinalize
            )
        }

        let degradationCodes = await fixture.repository
            .savedDegradationCodes()
        let finalizeAttemptCodes = await fixture.repository
            .finalizeAttemptDegradationErrorCodes()
        let persistedState = await fixture.repository.savedState(
            for: meetingID
        )
        XCTAssertEqual(
            degradationCodes,
            ["source_track_finish_failed_microphone"]
        )
        XCTAssertEqual(
            finalizeAttemptCodes,
            ["source_track_finish_failed_microphone"]
        )
        XCTAssertEqual(
            persistedState,
            .finalizing
        )
    }

    func testFinalTranscriptTailAndPendingDegradationPersistAtomicallyAtFinalization()
        async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            transcriptionChunkSampleCount: 4,
            transcriberEmitsDrafts: true,
            writerFailsAppendTracks: [.microphone],
            repositoryDegradationFailures: 1
        )

        let meetingID = try await fixture.coordinator.start(mode: .online)
        for _ in 0..<1_000 {
            let attempts = await fixture.repository
                .degradationPersistenceAttemptCount()
            let masterFrameCount = await fixture.writer(for: .master)
                .writtenFrames()
                .count
            if attempts == 1, masterFrameCount == 1 {
                break
            }
            await Task.yield()
        }

        let attemptsBeforeStop = await fixture.repository
            .degradationPersistenceAttemptCount()
        let codesBeforeStop = await fixture.repository
            .savedDegradationCodes()
        XCTAssertEqual(attemptsBeforeStop, 1)
        XCTAssertTrue(codesBeforeStop.isEmpty)

        try await fixture.coordinator.stop()

        let attempts = await fixture.repository
            .degradationPersistenceAttemptCount()
        let codes = await fixture.repository.savedDegradationCodes()
        let transcripts = await fixture.repository.savedTranscripts()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let savedFinalization = await fixture.repository.finalization()
        let finalization = try XCTUnwrap(savedFinalization)
        let events = await fixture.events.values()
        let drain = try XCTUnwrap(
            events.firstIndex(of: "transcriber.drain")
        )
        let finishUpdates = try XCTUnwrap(
            events.firstIndex(of: "transcriber.finishUpdates")
        )
        let transcriptSaved = try XCTUnwrap(
            events.firstIndex(of: "repository.transcript")
        )
        let finalized = try XCTUnwrap(
            events.firstIndex(of: "repository.finalize")
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(codes, ["source_track_write_failed_microphone"])
        XCTAssertEqual(transcripts.map(\.text), ["chunk-0"])
        XCTAssertEqual(
            finalization.sourceDegradationErrorCode,
            "source_track_write_failed_microphone"
        )
        XCTAssertLessThan(drain, finishUpdates)
        XCTAssertLessThan(finishUpdates, finalized)
        XCTAssertLessThan(transcriptSaved, finalized)
        XCTAssertEqual(persistedState, .ready)
    }

    func testAtomicFinalizationFailurePreservesTailAndBlocksReadyTransition()
        async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            transcriptionChunkSampleCount: 4,
            transcriberEmitsDrafts: true,
            writerFailsAppendTracks: [.microphone],
            repositoryDegradationFailures: 1,
            repositoryFailsFinalize: true
        )

        let meetingID = try await fixture.coordinator.start(mode: .online)
        for _ in 0..<1_000 {
            if await fixture.repository
                .degradationPersistenceAttemptCount() == 1 {
                break
            }
            await Task.yield()
        }
        await fixture.events.removeAll()

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected repository finalize failure")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorTestError,
                .repositoryFinalize
            )
        }

        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        let attempts = await fixture.repository
            .degradationPersistenceAttemptCount()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let codes = await fixture.repository.savedDegradationCodes()
        let transcripts = await fixture.repository.savedTranscripts()
        let finalization = await fixture.repository.finalization()
        let finalizeAttemptCodes = await fixture.repository
            .finalizeAttemptDegradationErrorCodes()
        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(codes.isEmpty)
        XCTAssertEqual(transcripts.map(\.text), ["chunk-0"])
        XCTAssertNil(finalization)
        XCTAssertEqual(
            finalizeAttemptCodes,
            ["source_track_write_failed_microphone"]
        )
        XCTAssertTrue(events.contains("transcriber.drain"))
        XCTAssertTrue(events.contains("transcriber.finishUpdates"))
        XCTAssertTrue(events.contains("repository.finalize.attempt"))
        XCTAssertFalse(events.contains("repository.finalize"))
        XCTAssertEqual(
            events.filter { $0 == "transcriber.drain" }.count,
            1
        )
        XCTAssertEqual(
            events.filter { $0 == "transcriber.finishUpdates" }.count,
            1
        )
        XCTAssertEqual(
            events.filter { $0 == "repository.finalize.attempt" }.count,
            1
        )
        XCTAssertEqual(snapshot.state, .finalizing)
        XCTAssertEqual(snapshot.meetingID, meetingID)
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(persistedState, .finalizing)
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testSourceFinishFailurePersistsDegradationAndStillFinalizesMaster() async throws {
        let fixture = makeFixture(
            writerFailsFinishTracks: [.microphone]
        )

        let meetingID = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.stop()

        let codes = await fixture.repository.savedDegradationCodes()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let finalization = await fixture.repository.finalization()
        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(codes, ["source_track_finish_failed_microphone"])
        XCTAssertEqual(persistedState, .ready)
        XCTAssertNotNil(finalization)
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testOnlineStopFinishesSourceWritersBeforePostProcessing() async throws {
        let fixture = makeFixture()
        try await fixture.coordinator.start(mode: .online)
        await fixture.events.removeAll()

        try await fixture.coordinator.stop()

        let events = await fixture.events.values()
        let microphoneFinish = try XCTUnwrap(
            events.firstIndex(of: "writer.microphone.finish")
        )
        let systemFinish = try XCTUnwrap(
            events.firstIndex(of: "writer.system.finish")
        )
        let transcriptionDrain = try XCTUnwrap(
            events.firstIndex(of: "transcriber.drain")
        )
        XCTAssertLessThan(microphoneFinish, transcriptionDrain)
        XCTAssertLessThan(systemFinish, transcriptionDrain)
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testPrepareForDeletionDiscardsRecordingWithoutFinalization() async throws {
        let fixture = makeFixture(
            speakerDiarizationEnabled: true,
            speakerFinalizationOutcome: .unchanged
        )
        let meetingID = try await fixture.coordinator.start(mode: .offline)
        await fixture.events.removeAll()

        try await fixture.coordinator.prepareForDeletion(id: meetingID)

        let snapshot = await fixture.coordinator.snapshot()
        let events = await fixture.events.values()
        let cancelCount = await fixture.transcriber.cancelCount()
        let savedState = await fixture.repository.savedState(for: meetingID)
        let speakerRequests = await fixture.speakerFinalizer.recordedRequests()
        let panelCalls = await fixture.panel.calls()
        let presentationEvents = await fixture.recordingPresentation.events()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(savedState, .recording)
        XCTAssertTrue(speakerRequests.isEmpty)
        XCTAssertFalse(events.contains("repository.finalize.attempt"))
        XCTAssertFalse(events.contains("repository.finalize"))
        XCTAssertFalse(events.contains("repository.delete"))
        XCTAssertTrue(events.contains("capture.stop"))
        XCTAssertTrue(events.contains("writer.finish"))
        XCTAssertEqual(panelCalls, ["show", "hide"])
        XCTAssertEqual(presentationEvents.last, .clear(meetingID: meetingID))
    }

    func testPrepareForDeletionDiscardsPausedMeeting() async throws {
        let fixture = makeFixture()
        let meetingID = try await fixture.coordinator.start(mode: .online)
        try await fixture.coordinator.pauseOrResume()

        try await fixture.coordinator.prepareForDeletion(id: meetingID)

        let snapshot = await fixture.coordinator.snapshot()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let sourceFinishCounts = await [
            fixture.writer(for: .microphone).finishCallCount(),
            fixture.writer(for: .system).finishCallCount()
        ]
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(persistedState, .paused)
        XCTAssertEqual(sourceFinishCounts, [1, 1])
    }

    func testPrepareForDeletionDuringStartPreventsLateRecordingRevival()
        async throws {
        let fixture = makeFixture(captureSuspendsStart: true)
        let createdMeeting = MeetingCreationProbe()
        let start = Task {
            try await fixture.coordinator.start(
                mode: .offline,
                onMeetingCreated: { meetingID in
                    await createdMeeting.record(meetingID)
                }
            )
        }
        let meetingID = await createdMeeting.waitForMeetingID()
        for _ in 0..<1_000 where !(await fixture.capture.isStartSuspended()) {
            await Task.yield()
        }

        let deletion = Task {
            try await fixture.coordinator.prepareForDeletion(id: meetingID)
        }
        for _ in 0..<1_000 {
            if await fixture.events.values().contains("capture.stop") {
                break
            }
            await Task.yield()
        }
        await fixture.capture.resumeSuspendedStart()

        do {
            _ = try await start.value
            XCTFail("Expected intentionally discarded startup to cancel")
        } catch is CancellationError {
            // Expected: deletion owns persistent cleanup after startup unwinds.
        }
        try await deletion.value

        let snapshot = await fixture.coordinator.snapshot()
        let savedState = await fixture.repository.savedState(for: meetingID)
        let events = await fixture.events.values()
        let panelCalls = await fixture.panel.calls()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(savedState, .preparing)
        XCTAssertFalse(events.contains("repository.delete"))
        XCTAssertFalse(events.contains("repository.finalize"))
        XCTAssertFalse(panelCalls.contains("show"))
    }

    func testProductionTranscriptionEnqueuesAtTenSecondsWhileRecording() async throws {
        let tenSeconds = 10 * Int(AudioSegmentManifest.transcriptionSampleRate)
        let transcriptionSamples = Array(repeating: Float(0.1), count: tenSeconds)
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: transcriptionSamples,
            transcriptionSamples: transcriptionSamples,
            transcriptionSampleRate: AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(frames: [frame])

        try await fixture.coordinator.start(mode: .offline)
        for _ in 0..<1_000 {
            if await fixture.transcriber.chunks().count == 1 {
                break
            }
            await Task.yield()
        }

        let snapshot = await fixture.coordinator.snapshot()
        let written = await fixture.writer.writtenFrames()
        let chunks = await fixture.transcriber.chunks()
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(
            written.map(\.sampleRate),
            [PCMConverter.playbackSampleRate]
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.samples.count, tenSeconds)
        XCTAssertEqual(chunks.first?.startingAt, 0)
        try await fixture.coordinator.stop()
    }

    func testPersistsTranscriptionUpdatesWhileRecordingIsStillActive() async throws {
        let transcriptionSamples: [Float] = [0, 1, 2, 3]
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: transcriptionSamples,
            transcriptionSamples: transcriptionSamples,
            transcriptionSampleRate: AudioSegmentManifest.transcriptionSampleRate
        )
        let fixture = makeFixture(
            frames: [frame],
            transcriptionChunkSampleCount: 4,
            transcriberEmitsDrafts: true
        )

        try await fixture.coordinator.start(mode: .offline)
        for _ in 0..<1_000 {
            if await fixture.repository.savedTranscripts().count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let snapshot = await fixture.coordinator.snapshot()
        let transcripts = await fixture.repository.savedTranscripts()
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(transcripts.map(\.text), ["chunk-0"])
        try await fixture.coordinator.stop()
    }

    func testAudioWriteFailureFinalizesInterruptedMeetingInsteadOfBufferingForever()
        async throws {
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: 16_000,
            samples: [0, 1, 2, 3]
        )
        let fixture = makeFixture(frames: [frame], writerFailsAppend: true)

        let meetingID = try await fixture.coordinator.start(mode: .offline)
        for _ in 0..<1_000 {
            if await fixture.interruptionReporter.meetingIDs().contains(
                meetingID
            ) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        let interruption = await fixture.repository
            .interruptionFinalization()
        XCTAssertTrue(events.contains("capture.stop"))
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertEqual(interruption?.meetingID, meetingID)
    }

    func testWriterFinalizationFailureStillClosesTranscriptUpdatesAndPanel() async throws {
        let fixture = makeFixture(writerFailsFinish: true)
        try await fixture.coordinator.start(mode: .offline)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected writer finalization failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .writerFinish)
        }

        let updatesFinished = await fixture.transcriber.didFinishUpdates()
        let panelCalls = await fixture.panel.calls()
        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertTrue(updatesFinished)
        XCTAssertEqual(panelCalls, ["show", "hide"])
        XCTAssertEqual(snapshot.state, .finalizing)
        XCTAssertNotNil(snapshot.meetingID)
        XCTAssertEqual(snapshot.mode, .offline)
    }

    func testRepositoryFinalizeFailurePreservesFailedSessionDiagnostics() async throws {
        let fixture = makeFixture(
            packets: [
                makeHealthPacket(
                    microphoneSamples: [0.2],
                    systemSamples: [0.3]
                )
            ],
            repositoryFailsFinalize: true
        )
        let meetingID = try await fixture.coordinator.start(mode: .online)
        await waitForMasterFrames(1, fixture: fixture)
        await fixture.clock.setMonotonic(125)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected repository finalize failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .repositoryFinalize)
        }

        let snapshot = await fixture.coordinator.snapshot()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(snapshot.state, .finalizing)
        XCTAssertEqual(snapshot.meetingID, meetingID)
        XCTAssertEqual(snapshot.mode, .online)
        XCTAssertEqual(snapshot.activeTime, 25, accuracy: 0.001)
        XCTAssertEqual(persistedState, .finalizing)
        XCTAssertEqual(masterFinishCount, 1)
        XCTAssertEqual(microphoneFinishCount, 1)
        XCTAssertEqual(systemFinishCount, 1)
    }

    func testStartsNewMeetingAfterFinalizeFailureWithoutDeletingRecoveryRecord() async throws {
        let fixture = makeFixture(repositoryFailsFinalize: true)
        let failedMeetingID = try await fixture.coordinator.start(mode: .online)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected repository finalize failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .repositoryFinalize)
        }

        let newMeetingID = try await fixture.coordinator.start(mode: .offline)

        let snapshot = await fixture.coordinator.snapshot()
        let meetings = await fixture.repository.savedMeetings()
        XCTAssertNotEqual(newMeetingID, failedMeetingID)
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(snapshot.meetingID, newMeetingID)
        XCTAssertEqual(snapshot.mode, .offline)
        XCTAssertEqual(
            meetings,
            [
                .init(
                    id: failedMeetingID,
                    mode: .online,
                    state: .finalizing
                ),
                .init(
                    id: newMeetingID,
                    mode: .offline,
                    state: .recording
                )
            ],
            "新录音必须保留失败会话的 finalizing 记录供恢复服务处理"
        )
    }

    func testFinalizingPersistenceFailureKeepsRecorderVisibleForRetry() async throws {
        let fixture = makeFixture(repositoryFailsFinalizingUpdate: true)
        try await fixture.coordinator.start(mode: .offline)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected finalizing persistence failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .repositoryUpdate)
        }

        let panelCalls = await fixture.panel.calls()
        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertEqual(panelCalls, ["show"])
        XCTAssertFalse(events.contains("capture.stop"))
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertNotNil(snapshot.meetingID)
        XCTAssertEqual(snapshot.mode, .offline)
    }

    func testRejectsOverlappingPauseAndStopOperations() async throws {
        let fixture = makeFixture(captureSuspendsPause: true)
        try await fixture.coordinator.start(mode: .offline)
        let pauseTask = Task {
            try await fixture.coordinator.pauseOrResume()
        }

        for _ in 0..<100 {
            if await fixture.capture.isPauseSuspended() {
                break
            }
            await Task.yield()
        }
        let pauseIsSuspended = await fixture.capture.isPauseSuspended()
        XCTAssertTrue(pauseIsSuspended)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected overlapping stop to be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .operationInProgress
            )
        }

        await fixture.capture.resumeSuspendedPause()
        try await pauseTask.value
        try await fixture.coordinator.stop()
    }

    private func makeOnlinePacket(index: Int) -> CapturedAudioPacket {
        let timestamp = Double(index)
        let sample = Float(index)
        let master = CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [sample],
            transcriptionSamples: [sample],
            transcriptionSampleRate: 16_000
        )
        let microphone = CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [Float(10 + index)]
        )
        let system = CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [Float(20 + index)]
        )
        return CapturedAudioPacket(
            master: master,
            sourceFrames: [
                .microphone: microphone,
                .system: system
            ]
        )
    }

    private func makeHealthPacket(
        microphoneSamples: [Float],
        systemSamples: [Float]
    ) -> CapturedAudioPacket {
        let masterSamples = zip(
            microphoneSamples,
            systemSamples
        ).map(+)
        return CapturedAudioPacket(
            master: CapturedAudioFrame(
                timestamp: 0,
                sampleRate: PCMConverter.playbackSampleRate,
                samples: masterSamples,
                transcriptionSamples: masterSamples,
                transcriptionSampleRate:
                    AudioSegmentManifest.transcriptionSampleRate
            ),
            sourceFrames: [
                .microphone: CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: PCMConverter.playbackSampleRate,
                    samples: microphoneSamples
                ),
                .system: CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: PCMConverter.playbackSampleRate,
                    samples: systemSamples
                )
            ]
        )
    }

    private func waitForMasterFrames(
        _ count: Int,
        fixture: CoordinatorFixture
    ) async {
        for _ in 0..<1_000 {
            if await fixture.writer.writtenFrames().count == count {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for master frames")
    }

    private func waitForHealthCode(
        _ code: MeetingCaptureHealthCode,
        fixture: CoordinatorFixture
    ) async {
        for _ in 0..<1_000 {
            if await fixture.coordinator.snapshot().captureHealthCode == code {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for capture health update")
    }

    private func makeFixture(
        permissions: [CapturePermission: CapturePermissionStatus] = [
            .microphone: .authorized,
            .screenRecording: .authorized
        ],
        captureFailsToStart: Bool = false,
        captureSuspendsStart: Bool = false,
        frames: [CapturedAudioFrame] = [],
        packets: [CapturedAudioPacket]? = nil,
        transcriptionChunkSampleCount: Int? = nil,
        transcriberEmitsDrafts: Bool = false,
        fixedTranscriptionService: (any TranscriptionService)? = nil,
        writerFailsAppend: Bool = false,
        writerFailsFinish: Bool = false,
        writerFailsAppendTracks: Set<AudioTrack> = [],
        writerFailsFinishTracks: Set<AudioTrack> = [],
        writerFactoryFailsForTrack: AudioTrack? = nil,
        repositoryDegradationFailures: Int = 0,
        repositoryFailsSpeakerProcessingStart: Bool = false,
        repositoryFailsFinalizingUpdate: Bool = false,
        repositoryFailsReplacement: Bool = false,
        repositoryFailsFinalize: Bool = false,
        captureSuspendsPause: Bool = false,
        speakerDiarizationEnabled: Bool = false,
        speakerFinalizationOutcome: SpeakerFinalizationOutcome? = nil,
        blockingTranscriptionFactoryOutcome:
            BlockingCoordinatorTranscriptionFactory.Outcome? = nil,
        clockSuspendsNextDateRead: Bool = false,
        repositorySuspendsCreateMeeting: Bool = false
    ) -> CoordinatorFixture {
        let events = CoordinatorEventLog()
        let captureModes = CoordinatorModeLog()
        let writerRequests = CoordinatorWriterRequestLog()
        let capture = FakeCoordinatorCapture(
            events: events,
            failsToStart: captureFailsToStart,
            packets: packets ?? frames.map {
                CapturedAudioPacket(master: $0, sourceFrames: [:])
            },
            suspendsStart: captureSuspendsStart,
            suspendsPause: captureSuspendsPause
        )
        let writers = Dictionary(
            uniqueKeysWithValues: AudioTrack.allCases.map { track in
                (
                    track,
                    FakeCoordinatorWriter(
                        track: track,
                        events: events,
                        failsAppend: writerFailsAppendTracks.contains(track)
                            || (track == .master && writerFailsAppend),
                        failsFinish: writerFailsFinishTracks.contains(track)
                            || (track == .master && writerFailsFinish)
                    )
                )
            }
        )
        let transcriber = FakeCoordinatorTranscriber(
            events: events,
            emitsDrafts: transcriberEmitsDrafts,
            fixedTranscriptionService: fixedTranscriptionService
        )
        let blockingTranscriptionFactory =
            blockingTranscriptionFactoryOutcome.map {
                let entrySignal = CoordinatorTestSignal(
                    description: "transcription factory entered"
                )
                return BlockingCoordinatorTranscriptionFactory(
                    transcriber: transcriber,
                    outcome: $0,
                    entrySignal: entrySignal
                )
            }
        let transcriptionFactoryEntrySignal =
            blockingTranscriptionFactory?.entrySignal
        let transcriptionFactory: any MeetingTranscriptionQueueFactory =
            blockingTranscriptionFactory
                ?? FakeCoordinatorTranscriptionFactory(
                    transcriber: transcriber
                )
        let repository = FakeCoordinatorRepository(
            events: events,
            degradationFailures: repositoryDegradationFailures,
            failsSpeakerProcessingStart:
                repositoryFailsSpeakerProcessingStart,
            failsFinalizingUpdate: repositoryFailsFinalizingUpdate,
            failsReplacement: repositoryFailsReplacement,
            failsFinalize: repositoryFailsFinalize,
            suspendsCreateMeeting: repositorySuspendsCreateMeeting
        )
        let speakerFinalizer = FakeCoordinatorSpeakerFinalizer(
            events: events,
            outcome: speakerFinalizationOutcome ?? .unchanged,
            recordsEvent: speakerFinalizationOutcome != nil
        )
        let panel = FakeCoordinatorPanel(events: events)
        let clock = ManualCoordinatorClock(
            date: Date(timeIntervalSince1970: 1_000),
            monotonic: 100,
            suspendsNextDateRead: clockSuspendsNextDateRead
        )
        let healthScheduler = ManualCaptureHealthScheduler()
        let recordingPresentation = RecordingPresentationSpy()
        let interruptionReporter = CaptureInterruptionReporterSpy()
        let speakerDiarizationPreference =
            MutableSpeakerDiarizationPreference(
                isEnabled: speakerDiarizationEnabled
            )
        let dependencies = MeetingCoordinatorDependencies(
            permissions: FakeCoordinatorPermissions(statuses: permissions),
            captureFactory: FakeCoordinatorCaptureFactory(
                capture: capture,
                modes: captureModes
            ),
            writerFactory: FakeCoordinatorWriterFactory(
                writers: writers,
                requests: writerRequests,
                failsForTrack: writerFactoryFailsForTrack
            ),
            transcriptionFactory: transcriptionFactory,
            repository: repository,
            speakerDiarizationPreference: speakerDiarizationPreference,
            speakerFinalizer: speakerFinalizer,
            panel: panel,
            clock: clock,
            captureHealthScheduler: healthScheduler,
            recordingPresentation: recordingPresentation,
            captureInterruptionReporter: interruptionReporter
        )
        let coordinator: MeetingCoordinator
        if let transcriptionChunkSampleCount {
            coordinator = MeetingCoordinator(
                dependencies: dependencies,
                transcriptionChunkSampleCount: transcriptionChunkSampleCount
            )
        } else {
            coordinator = MeetingCoordinator(dependencies: dependencies)
        }
        return CoordinatorFixture(
            coordinator: coordinator,
            events: events,
            captureModes: captureModes,
            writerRequests: writerRequests,
            capture: capture,
            writers: writers,
            transcriber: transcriber,
            blockingTranscriptionFactory: blockingTranscriptionFactory,
            transcriptionFactoryEntrySignal:
                transcriptionFactoryEntrySignal,
            repository: repository,
            speakerDiarizationPreference: speakerDiarizationPreference,
            speakerFinalizer: speakerFinalizer,
            panel: panel,
            clock: clock,
            healthScheduler: healthScheduler,
            recordingPresentation: recordingPresentation,
            interruptionReporter: interruptionReporter
        )
    }

    @MainActor
    private func makeRealRepositoryFixture(
        speakerDiarizationEnabled: Bool,
        speakerFinalizationOutcome: SpeakerFinalizationOutcome
    ) throws -> RealRepositoryCoordinatorFixture {
        let events = CoordinatorEventLog()
        let capture = FakeCoordinatorCapture(
            events: events,
            failsToStart: false,
            packets: [],
            suspendsStart: false,
            suspendsPause: false
        )
        let writers = Dictionary(
            uniqueKeysWithValues: AudioTrack.allCases.map { track in
                (
                    track,
                    FakeCoordinatorWriter(
                        track: track,
                        events: events,
                        failsAppend: false,
                        failsFinish: false
                    )
                )
            }
        )
        let repository = try MeetingRepository.inMemory()
        let speakerFinalizer =
            RepositoryInspectingCoordinatorSpeakerFinalizer(
                repository: repository,
                outcome: speakerFinalizationOutcome
            )
        let dependencies = MeetingCoordinatorDependencies(
            permissions: FakeCoordinatorPermissions(
                statuses: [
                    .microphone: .authorized,
                    .screenRecording: .authorized
                ]
            ),
            captureFactory: FakeCoordinatorCaptureFactory(
                capture: capture,
                modes: CoordinatorModeLog()
            ),
            writerFactory: FakeCoordinatorWriterFactory(
                writers: writers,
                requests: CoordinatorWriterRequestLog(),
                failsForTrack: nil
            ),
            transcriptionFactory: FakeCoordinatorTranscriptionFactory(
                transcriber: FakeCoordinatorTranscriber(
                    events: events,
                    emitsDrafts: false,
                    fixedTranscriptionService: nil
                )
            ),
            repository: MeetingRepositoryLifecycleAdapter(
                repository: repository
            ),
            speakerDiarizationPreference:
                MutableSpeakerDiarizationPreference(
                    isEnabled: speakerDiarizationEnabled
                ),
            speakerFinalizer: speakerFinalizer,
            panel: FakeCoordinatorPanel(events: events),
            clock: ManualCoordinatorClock(
                date: Date(timeIntervalSince1970: 1_000),
                monotonic: 100
            )
        )
        return RealRepositoryCoordinatorFixture(
            coordinator: MeetingCoordinator(dependencies: dependencies),
            repository: repository,
            speakerFinalizer: speakerFinalizer
        )
    }
}

private struct CoordinatorFixture {
    let coordinator: MeetingCoordinator
    let events: CoordinatorEventLog
    let captureModes: CoordinatorModeLog
    let writerRequests: CoordinatorWriterRequestLog
    let capture: FakeCoordinatorCapture
    let writers: [AudioTrack: FakeCoordinatorWriter]
    let transcriber: FakeCoordinatorTranscriber
    let blockingTranscriptionFactory:
        BlockingCoordinatorTranscriptionFactory?
    let transcriptionFactoryEntrySignal: CoordinatorTestSignal?
    let repository: FakeCoordinatorRepository
    let speakerDiarizationPreference: MutableSpeakerDiarizationPreference
    let speakerFinalizer: FakeCoordinatorSpeakerFinalizer
    let panel: FakeCoordinatorPanel
    let clock: ManualCoordinatorClock
    let healthScheduler: ManualCaptureHealthScheduler
    let recordingPresentation: RecordingPresentationSpy
    let interruptionReporter: CaptureInterruptionReporterSpy

    var writer: FakeCoordinatorWriter {
        writer(for: .master)
    }

    func writer(for track: AudioTrack) -> FakeCoordinatorWriter {
        guard let writer = writers[track] else {
            preconditionFailure("Missing fake writer for \(track)")
        }
        return writer
    }
}

private final class ManualCaptureHealthScheduler:
    CaptureHealthCheckScheduling,
    @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func checks() -> AsyncStream<Void> {
        stream
    }

    func runNextCheck() {
        lock.withLock {
            continuation.yield(())
        }
    }
}

@MainActor
private struct RealRepositoryCoordinatorFixture {
    let coordinator: MeetingCoordinator
    let repository: MeetingRepository
    let speakerFinalizer: RepositoryInspectingCoordinatorSpeakerFinalizer
}

private enum CoordinatorTestError: Error, Equatable {
    case captureStart
    case transcriptionFactory
    case repositoryUpdate
    case repositoryDegradation
    case repositorySpeakerProcessing
    case writerAppend
    case writerFactory
    case writerFinish
    case repositoryReplacement
    case repositoryFinalize
}

private actor CoordinatorEventLog {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    func values() -> [String] {
        entries
    }

    func removeAll() {
        entries.removeAll()
    }
}

private actor MeetingCreationProbe {
    private var meetingID: UUID?
    private var waiters: [CheckedContinuation<UUID, Never>] = []

    func record(_ meetingID: UUID) {
        self.meetingID = meetingID
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: meetingID) }
    }

    func waitForMeetingID() async -> UUID {
        if let meetingID { return meetingID }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CoordinatorModeLog {
    private var modes: [MeetingMode] = []

    func append(_ mode: MeetingMode) {
        modes.append(mode)
    }

    func values() -> [MeetingMode] {
        modes
    }
}

private actor CoordinatorWriterRequestLog {
    struct Request: Equatable, Sendable {
        let meetingID: UUID
        let track: AudioTrack
        let sampleRate: Double
    }

    private var requests: [Request] = []

    func append(_ request: Request) {
        requests.append(request)
    }

    func values() -> [Request] {
        requests
    }
}

private struct FakeCoordinatorPermissions: MeetingPermissionAuthorizing {
    let statuses: [CapturePermission: CapturePermissionStatus]

    func requestRequiredPermissions(
        for mode: MeetingMode
    ) async -> [CapturePermission: CapturePermissionStatus] {
        Dictionary(
            uniqueKeysWithValues: CapturePermissionClient
                .requiredPermissions(for: mode)
                .map { ($0, statuses[$0] ?? .denied) }
        )
    }
}

private struct FakeCoordinatorCaptureFactory: MeetingCaptureSourceFactory {
    let capture: FakeCoordinatorCapture
    let modes: CoordinatorModeLog

    func makeCapture(for mode: MeetingMode) async throws -> any AudioCaptureSource {
        await modes.append(mode)
        return capture
    }
}

private actor FakeCoordinatorCapture: AudioCaptureSource {
    private let events: CoordinatorEventLog
    private let failsToStart: Bool
    private let packets: [CapturedAudioPacket]
    private let suspendsStart: Bool
    private let suspendsPause: Bool
    private var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    init(
        events: CoordinatorEventLog,
        failsToStart: Bool,
        packets: [CapturedAudioPacket],
        suspendsStart: Bool,
        suspendsPause: Bool
    ) {
        self.events = events
        self.failsToStart = failsToStart
        self.packets = packets
        self.suspendsStart = suspendsStart
        self.suspendsPause = suspendsPause
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        await events.append("capture.start")
        if failsToStart {
            throw CoordinatorTestError.captureStart
        }
        let pair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream()
        continuation = pair.continuation
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        for packet in packets {
            continuation?.yield(packet)
        }
        return pair.stream
    }

    func pause() async throws {
        await events.append("capture.pause")
        if suspendsPause {
            await withCheckedContinuation { pauseContinuation = $0 }
        }
    }

    func resume() async throws {
        await events.append("capture.resume")
    }

    func stop() async {
        await events.append("capture.stop")
        continuation?.finish()
        continuation = nil
    }

    func failStream() {
        continuation?.finish(throwing: CoordinatorTestError.captureStart)
        continuation = nil
    }

    func isPauseSuspended() -> Bool {
        pauseContinuation != nil
    }

    func isStartSuspended() -> Bool {
        startContinuation != nil
    }

    func resumeSuspendedStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeSuspendedPause() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private struct FakeCoordinatorWriterFactory: MeetingAudioWriterFactory {
    let writers: [AudioTrack: FakeCoordinatorWriter]
    let requests: CoordinatorWriterRequestLog
    let failsForTrack: AudioTrack?

    func makeWriter(
        meetingID: UUID,
        track: AudioTrack,
        sampleRate: Double
    ) async throws -> any MeetingAudioWriting {
        await requests.append(
            .init(
                meetingID: meetingID,
                track: track,
                sampleRate: sampleRate
            )
        )
        if failsForTrack == track {
            throw CoordinatorTestError.writerFactory
        }
        guard let writer = writers[track] else {
            preconditionFailure("Missing fake writer for \(track)")
        }
        await writer.configure(expectedSampleRate: sampleRate)
        return writer
    }
}

private actor FakeCoordinatorWriter: MeetingAudioWriting {
    private let track: AudioTrack
    private let events: CoordinatorEventLog
    private let failsAppend: Bool
    private let failsFinish: Bool
    private var expectedSampleRate: Double?
    private var frames: [CapturedAudioFrame] = []
    private var appendCalls = 0
    private var finishCalls = 0

    init(
        track: AudioTrack,
        events: CoordinatorEventLog,
        failsAppend: Bool,
        failsFinish: Bool
    ) {
        self.track = track
        self.events = events
        self.failsAppend = failsAppend
        self.failsFinish = failsFinish
    }

    func configure(expectedSampleRate: Double) {
        self.expectedSampleRate = expectedSampleRate
    }

    func append(_ frame: CapturedAudioFrame) async throws {
        appendCalls += 1
        guard let expectedSampleRate,
              abs(frame.sampleRate - expectedSampleRate) < 0.001 else {
            throw CoordinatorTestError.writerAppend
        }
        if failsAppend {
            throw CoordinatorTestError.writerAppend
        }
        frames.append(frame)
    }

    func finish() async throws -> AudioSegmentManifest {
        finishCalls += 1
        let event = track == .master
            ? "writer.finish"
            : "writer.\(track.rawValue).finish"
        await events.append(event)
        if failsFinish {
            throw CoordinatorTestError.writerFinish
        }
        return AudioSegmentManifest()
    }

    func writtenFrames() -> [CapturedAudioFrame] {
        frames
    }

    func appendCallCount() -> Int {
        appendCalls
    }

    func finishCallCount() -> Int {
        finishCalls
    }
}

private struct FakeCoordinatorTranscriptionFactory: MeetingTranscriptionQueueFactory {
    let transcriber: FakeCoordinatorTranscriber

    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        transcriber
    }
}

private final class CoordinatorTestSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var storedCount = 0

    init(description: String) {
        expectation = XCTestExpectation(description: description)
        expectation.assertForOverFulfill = true
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func signal() {
        lock.withLock { storedCount += 1 }
        expectation.fulfill()
    }
}

private actor BlockingCoordinatorTranscriptionFactory:
    MeetingTranscriptionQueueFactory {
    enum Outcome: Sendable {
        case success
        case failure
    }

    private let transcriber: FakeCoordinatorTranscriber
    private let outcome: Outcome
    nonisolated let entrySignal: CoordinatorTestSignal
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transcriber: FakeCoordinatorTranscriber,
        outcome: Outcome,
        entrySignal: CoordinatorTestSignal
    ) {
        self.transcriber = transcriber
        self.outcome = outcome
        self.entrySignal = entrySignal
    }

    func makeQueue() async throws -> any MeetingTranscriptionQueueing {
        entrySignal.signal()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        switch outcome {
        case .success:
            return transcriber
        case .failure:
            throw CoordinatorTestError.transcriptionFactory
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll(keepingCapacity: false)
        releaseWaiters.forEach { $0.resume() }
    }
}

private actor FakeCoordinatorTranscriber: MeetingTranscriptionQueueing {
    struct Chunk: Equatable, Sendable {
        let samples: [Float]
        let startingAt: TimeInterval
    }

    private let events: CoordinatorEventLog
    private let emitsDrafts: Bool
    private let fixedService: (any TranscriptionService)?
    private var receivedChunks: [Chunk] = []
    private var completedDrafts: [TranscriptDraft] = []
    private var updateContinuation: AsyncStream<TranscriptDraft>.Continuation?
    private var updatesFinished = false
    private var cancellationCount = 0
    private var isCancelled = false

    init(
        events: CoordinatorEventLog,
        emitsDrafts: Bool,
        fixedTranscriptionService: (any TranscriptionService)? = nil
    ) {
        self.events = events
        self.emitsDrafts = emitsDrafts
        fixedService = fixedTranscriptionService
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) async {
        receivedChunks.append(Chunk(samples: samples, startingAt: startingAt))
        if emitsDrafts {
            let draft = TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + Double(samples.count) / 16_000,
                text: "chunk-\(Int(startingAt))"
            )
            completedDrafts.append(draft)
            updateContinuation?.yield(draft)
        }
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        await events.append("transcriber.cancel")
        cancellationCount += 1
        receivedChunks.removeAll(keepingCapacity: false)
        completedDrafts.removeAll(keepingCapacity: false)
        updateContinuation?.finish()
        updateContinuation = nil
    }

    func drain() async {
        await events.append("transcriber.drain")
    }

    func transcripts() async -> [TranscriptDraft] {
        completedDrafts
    }

    func updates() async -> AsyncStream<TranscriptDraft> {
        let pair = AsyncStream<TranscriptDraft>.makeStream()
        updateContinuation = pair.continuation
        return pair.stream
    }

    func finishUpdates() async {
        await events.append("transcriber.finishUpdates")
        updateContinuation?.finish()
        updateContinuation = nil
        updatesFinished = true
    }

    func fixedTranscriptionService() -> (any TranscriptionService)? {
        fixedService
    }

    func chunks() -> [Chunk] {
        receivedChunks
    }

    func didFinishUpdates() -> Bool {
        updatesFinished
    }

    func cancelCount() -> Int {
        cancellationCount
    }
}

private actor FakeCoordinatorSpeakerFinalizer:
    MeetingSpeakerFinalizing {
    struct Request: Equatable, Sendable {
        let meetingID: UUID
        let mode: MeetingMode
        let diarizationRequested: Bool
        let provisional: [TranscriptDraft]
    }

    private let events: CoordinatorEventLog
    private let outcome: SpeakerFinalizationOutcome
    private let recordsEvent: Bool
    private var requests: [Request] = []
    private var fixedServiceMarkers: [String] = []

    init(
        events: CoordinatorEventLog,
        outcome: SpeakerFinalizationOutcome,
        recordsEvent: Bool
    ) {
        self.events = events
        self.outcome = outcome
        self.recordsEvent = recordsEvent
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        requests.append(
            Request(
                meetingID: meetingID,
                mode: mode,
                diarizationRequested: diarizationRequested,
                provisional: provisional
            )
        )
        if recordsEvent {
            await events.append("speaker.finalize")
        }
        return outcome
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft],
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome {
        if let marker = try? await transcriptionService.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text {
            fixedServiceMarkers.append(marker)
        }
        return await finalize(
            meetingID: meetingID,
            mode: mode,
            diarizationRequested: diarizationRequested,
            provisional: provisional
        )
    }

    func recordedRequests() -> [Request] {
        requests
    }

    func recordedFixedServiceMarkers() -> [String] {
        fixedServiceMarkers
    }
}

private actor FixedCoordinatorTranscriptionService: TranscriptionService {
    private let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        _ = samples
        return [
            TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + 1,
                text: marker
            )
        ]
    }
}

@MainActor
private final class RepositoryInspectingCoordinatorSpeakerFinalizer:
    MeetingSpeakerFinalizing {
    private let repository: MeetingRepository
    private let outcome: SpeakerFinalizationOutcome
    private(set) var observedStates: [SpeakerProcessingState] = []

    init(
        repository: MeetingRepository,
        outcome: SpeakerFinalizationOutcome
    ) {
        self.repository = repository
        self.outcome = outcome
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        _ = mode
        _ = diarizationRequested
        _ = provisional
        if let meeting = try? repository.meeting(id: meetingID) {
            observedStates.append(meeting.speakerProcessingState)
        }
        return outcome
    }
}

private actor FakeCoordinatorRepository: MeetingLifecycleRepository {
    struct SavedMeeting: Equatable, Sendable {
        let id: UUID
        let mode: MeetingMode
        var state: RecordingState
        var speakerDiarizationRequested = false
    }

    struct Finalization: Equatable, Sendable {
        let endedAt: Date
        let activeDuration: TimeInterval
        let sourceDegradationErrorCode: String?
    }

    struct SavedReplacement: Equatable, Sendable {
        let drafts: [AttributedTranscriptDraft]
        let sourceRevision: Int
    }

    struct InterruptionFinalization: Equatable, Sendable {
        let meetingID: UUID
        let endedAt: Date
        let activeDuration: TimeInterval
        let lastErrorCode: String
    }

    private let events: CoordinatorEventLog
    private var remainingDegradationFailures: Int
    private let failsSpeakerProcessingStart: Bool
    private let failsFinalizingUpdate: Bool
    private let failsReplacement: Bool
    private let failsFinalize: Bool
    nonisolated let createMeetingEntrySignal: CoordinatorTestSignal?
    private var suspendsCreateMeeting: Bool
    private var createMeetingWaiters: [CheckedContinuation<Void, Never>] = []
    private var meetings: [SavedMeeting] = []
    private var allCreatedMeetingIDs: [UUID] = []
    private var bookmarks: [TimeInterval] = []
    private var transcripts: [TranscriptDraft] = []
    private var degradationCodes: [String] = []
    private var degradationPersistenceAttempts = 0
    private var speakerProcessingStartAttempts = 0
    private var recordedFinalizeAttemptDegradationErrorCodes: [String?] = []
    private var savedFinalization: Finalization?
    private var replacement: SavedReplacement?
    private var interruption: InterruptionFinalization?
    private var interruptionCount = 0

    init(
        events: CoordinatorEventLog,
        degradationFailures: Int,
        failsSpeakerProcessingStart: Bool,
        failsFinalizingUpdate: Bool,
        failsReplacement: Bool,
        failsFinalize: Bool,
        suspendsCreateMeeting: Bool = false
    ) {
        self.events = events
        remainingDegradationFailures = degradationFailures
        self.failsSpeakerProcessingStart = failsSpeakerProcessingStart
        self.failsFinalizingUpdate = failsFinalizingUpdate
        self.failsReplacement = failsReplacement
        self.failsFinalize = failsFinalize
        self.suspendsCreateMeeting = suspendsCreateMeeting
        createMeetingEntrySignal = suspendsCreateMeeting
            ? CoordinatorTestSignal(
                description: "repository create meeting entered"
            )
            : nil
    }

    func createMeeting(
        mode: MeetingMode,
        startedAt: Date,
        speakerDiarizationRequested: Bool
    ) async throws -> UUID {
        _ = startedAt
        await events.append("repository.create")
        if suspendsCreateMeeting {
            createMeetingEntrySignal?.signal()
            await withCheckedContinuation { continuation in
                createMeetingWaiters.append(continuation)
            }
        }
        let meetingID = UUID()
        allCreatedMeetingIDs.append(meetingID)
        meetings.append(
            SavedMeeting(
                id: meetingID,
                mode: mode,
                state: .preparing,
                speakerDiarizationRequested: speakerDiarizationRequested
            )
        )
        return meetingID
    }

    func releaseCreateMeeting() {
        guard suspendsCreateMeeting else { return }
        suspendsCreateMeeting = false
        let waiters = createMeetingWaiters
        createMeetingWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func updateState(meetingID: UUID, state: RecordingState) async throws {
        if state == .finalizing {
            await events.append("repository.finalizing")
            if failsFinalizingUpdate {
                throw CoordinatorTestError.repositoryUpdate
            }
        }
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = state
        }
    }

    func appendBookmark(meetingID: UUID, timestamp: TimeInterval) async throws {
        _ = meetingID
        bookmarks.append(timestamp)
    }

    func appendTranscript(meetingID: UUID, draft: TranscriptDraft) async throws {
        _ = meetingID
        transcripts.append(draft)
        await events.append("repository.transcript")
    }

    func replaceTranscripts(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int
    ) async throws {
        _ = meetingID
        await events.append("repository.replace")
        if failsReplacement {
            throw CoordinatorTestError.repositoryReplacement
        }
        transcripts = drafts.map(\.transcript)
        replacement = SavedReplacement(
            drafts: drafts,
            sourceRevision: sourceRevision
        )
    }

    func markSpeakerProcessingDegraded(
        meetingID: UUID,
        errorCode: String
    ) async throws {
        _ = meetingID
        degradationPersistenceAttempts += 1
        if remainingDegradationFailures > 0 {
            remainingDegradationFailures -= 1
            throw CoordinatorTestError.repositoryDegradation
        }
        degradationCodes = [errorCode]
    }

    func markSpeakerProcessingStarted(meetingID: UUID) async throws {
        _ = meetingID
        speakerProcessingStartAttempts += 1
        if failsSpeakerProcessingStart {
            throw CoordinatorTestError.repositorySpeakerProcessing
        }
    }

    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        sourceDegradationErrorCode: String?
    ) async throws {
        recordedFinalizeAttemptDegradationErrorCodes.append(
            sourceDegradationErrorCode
        )
        await events.append("repository.finalize.attempt")
        if failsFinalize {
            throw CoordinatorTestError.repositoryFinalize
        }
        if let sourceDegradationErrorCode {
            degradationCodes = [sourceDegradationErrorCode]
        }
        savedFinalization = Finalization(
            endedAt: endedAt,
            activeDuration: activeDuration,
            sourceDegradationErrorCode: sourceDegradationErrorCode
        )
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .ready
        }
        await events.append("repository.finalize")
    }

    func finalizeInterruptedMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        lastErrorCode: String
    ) async throws {
        interruptionCount += 1
        interruption = InterruptionFinalization(
            meetingID: meetingID,
            endedAt: endedAt,
            activeDuration: activeDuration,
            lastErrorCode: lastErrorCode
        )
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .ready
        }
        await events.append("repository.interrupted")
    }

    func deleteMeeting(meetingID: UUID) async throws {
        meetings.removeAll { $0.id == meetingID }
        await events.append("repository.delete")
    }

    func savedBookmarks() -> [TimeInterval] {
        bookmarks
    }

    func savedTranscripts() -> [TranscriptDraft] {
        transcripts
    }

    func savedReplacement() -> SavedReplacement? {
        replacement
    }

    func savedDegradationCodes() -> [String] {
        degradationCodes
    }

    func degradationPersistenceAttemptCount() -> Int {
        degradationPersistenceAttempts
    }

    func speakerProcessingStartAttemptCount() -> Int {
        speakerProcessingStartAttempts
    }

    func finalizeAttemptDegradationErrorCodes() -> [String?] {
        recordedFinalizeAttemptDegradationErrorCodes
    }

    func finalization() -> Finalization? {
        savedFinalization
    }

    func interruptionFinalization() -> InterruptionFinalization? {
        interruption
    }

    func interruptionFinalizationCount() -> Int {
        interruptionCount
    }

    func savedMeetings() -> [SavedMeeting] {
        meetings
    }

    func createdMeetingIDs() -> [UUID] {
        allCreatedMeetingIDs
    }

    func savedState(for meetingID: UUID) -> RecordingState? {
        meetings.first(where: { $0.id == meetingID })?.state
    }
}

private final class MutableSpeakerDiarizationPreference:
    SpeakerDiarizationPreferenceReading,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsEnabled: Bool

    init(isEnabled: Bool) {
        storedIsEnabled = isEnabled
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedIsEnabled
        }
        set {
            lock.lock()
            storedIsEnabled = newValue
            lock.unlock()
        }
    }

    func isSpeakerDiarizationEnabled() async -> Bool {
        isEnabled
    }
}

private actor FakeCoordinatorPanel: RecordingPanelPresenting {
    private let events: CoordinatorEventLog
    private var panelCalls: [String] = []

    init(events: CoordinatorEventLog) {
        self.events = events
    }

    func show() async {
        panelCalls.append("show")
    }

    func hide() async {
        panelCalls.append("hide")
        await events.append("panel.hide")
    }

    func calls() -> [String] {
        panelCalls
    }
}

private actor ManualCoordinatorClock: MeetingClock {
    private var currentDate: Date
    private var currentMonotonic: TimeInterval
    nonisolated let dateReadEntrySignal: CoordinatorTestSignal?
    private var suspendsNextDateRead: Bool
    private var dateReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        date: Date,
        monotonic: TimeInterval,
        suspendsNextDateRead: Bool = false
    ) {
        currentDate = date
        currentMonotonic = monotonic
        self.suspendsNextDateRead = suspendsNextDateRead
        dateReadEntrySignal = suspendsNextDateRead
            ? CoordinatorTestSignal(description: "clock date read entered")
            : nil
    }

    func now() async -> Date {
        if suspendsNextDateRead {
            dateReadEntrySignal?.signal()
            await withCheckedContinuation { continuation in
                dateReadWaiters.append(continuation)
            }
        }
        return currentDate
    }

    func releaseDateRead() {
        guard suspendsNextDateRead else { return }
        suspendsNextDateRead = false
        let waiters = dateReadWaiters
        dateReadWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func monotonicNow() async -> TimeInterval {
        currentMonotonic
    }

    func setDate(_ date: Date) {
        currentDate = date
    }

    func setMonotonic(_ value: TimeInterval) {
        currentMonotonic = value
    }
}

private enum RecordingPresentationEvent: Equatable {
    case start(meetingID: UUID, monotonicTime: TimeInterval)
    case pause(meetingID: UUID, activeDuration: TimeInterval)
    case resume(
        meetingID: UUID,
        activeDuration: TimeInterval,
        monotonicTime: TimeInterval
    )
    case finish(meetingID: UUID, activeDuration: TimeInterval)
    case clear(meetingID: UUID)
}

private actor RecordingPresentationSpy:
    RecordingSessionPresentationUpdating {
    private var recordedEvents: [RecordingPresentationEvent] = []

    func start(meetingID: UUID, monotonicTime: TimeInterval) async {
        recordedEvents.append(
            .start(meetingID: meetingID, monotonicTime: monotonicTime)
        )
    }

    func pause(meetingID: UUID, activeDuration: TimeInterval) async {
        recordedEvents.append(
            .pause(meetingID: meetingID, activeDuration: activeDuration)
        )
    }

    func resume(
        meetingID: UUID,
        activeDuration: TimeInterval,
        monotonicTime: TimeInterval
    ) async {
        recordedEvents.append(
            .resume(
                meetingID: meetingID,
                activeDuration: activeDuration,
                monotonicTime: monotonicTime
            )
        )
    }

    func finish(meetingID: UUID, activeDuration: TimeInterval) async {
        recordedEvents.append(
            .finish(meetingID: meetingID, activeDuration: activeDuration)
        )
    }

    func clear(meetingID: UUID) async {
        recordedEvents.append(.clear(meetingID: meetingID))
    }

    func events() -> [RecordingPresentationEvent] {
        recordedEvents
    }
}

private actor CaptureInterruptionReporterSpy:
    MeetingCaptureInterruptionReporting {
    private var recordedMeetingIDs: [UUID] = []

    func captureInterrupted(meetingID: UUID) async {
        recordedMeetingIDs.append(meetingID)
    }

    func meetingIDs() -> [UUID] {
        recordedMeetingIDs
    }
}
