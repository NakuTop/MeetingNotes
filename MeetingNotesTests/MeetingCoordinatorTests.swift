import XCTest
@testable import MeetingNotes

final class MeetingCoordinatorTests: XCTestCase {
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

    func testPermissionsMustBeAuthorizedBeforeRecording() async throws {
        let fixture = makeFixture(
            permissions: [
                .microphone: .authorized,
                .screenRecording: .denied
            ]
        )

        do {
            try await fixture.coordinator.start(mode: .online)
            XCTFail("Expected denied screen permission")
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .permissionDenied([.screenRecording])
            )
        }

        let snapshot = await fixture.coordinator.snapshot()
        let events = await fixture.events.values()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertTrue(events.isEmpty)
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
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(
            events,
            [
                "repository.create",
                "capture.start",
                "capture.stop",
                "writer.finish",
                "transcriber.drain",
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

    func testStopUsesSafeOrderAndRejectsDuplicateLifecycleCommands() async throws {
        let fixture = makeFixture()
        let meetingID = try await fixture.coordinator.start(mode: .offline)

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

    func testSuccessfulStopClearsSessionDiagnosticsAfterFinalizingReadyMeeting() async throws {
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: 16_000,
            samples: [0, 1, 2, 3]
        )
        let fixture = makeFixture(frames: [frame], writerFailsAppend: true)
        let meetingID = try await fixture.coordinator.start(mode: .offline)
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
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.meetingID)
        XCTAssertNil(snapshot.mode)
        XCTAssertEqual(snapshot.activeTime, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.bookmarkCount, 0)
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(persistedState, .ready)
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

    func testSourceDegradationPersistenceRetriesBeforeFinalization() async throws {
        let fixture = makeFixture(
            packets: [
                makeOnlinePacket(index: 0),
                makeOnlinePacket(index: 1)
            ],
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
            if attempts == 1, masterFrameCount == 2 {
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
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let finalization = await fixture.repository.finalization()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(codes, ["source_track_write_failed_microphone"])
        XCTAssertEqual(persistedState, .ready)
        XCTAssertNotNil(finalization)
    }

    func testPersistentSourceDegradationPersistenceFailureBlocksFinalization() async throws {
        let fixture = makeFixture(
            packets: [makeOnlinePacket(index: 0)],
            writerFailsAppendTracks: [.microphone],
            repositoryDegradationFailures: 2
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
            XCTFail("Expected degradation persistence failure")
        } catch {
            XCTAssertEqual(
                error as? MeetingCoordinatorError,
                .sourceDegradationPersistenceFailed
            )
        }

        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        let attempts = await fixture.repository
            .degradationPersistenceAttemptCount()
        let persistedState = await fixture.repository.savedState(for: meetingID)
        let codes = await fixture.repository.savedDegradationCodes()
        let finalization = await fixture.repository.finalization()
        let canDelete = await fixture.coordinator.canDeleteMeeting(id: meetingID)
        let masterFinishCount = await fixture.writer(for: .master)
            .finishCallCount()
        let microphoneFinishCount = await fixture.writer(for: .microphone)
            .finishCallCount()
        let systemFinishCount = await fixture.writer(for: .system)
            .finishCallCount()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(codes.isEmpty)
        XCTAssertNil(finalization)
        XCTAssertFalse(events.contains("transcriber.drain"))
        XCTAssertFalse(events.contains("repository.finalize"))
        XCTAssertEqual(snapshot.state, .finalizing)
        XCTAssertEqual(snapshot.meetingID, meetingID)
        XCTAssertFalse(snapshot.captureFailed)
        XCTAssertEqual(persistedState, .finalizing)
        XCTAssertTrue(canDelete)
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

    func testDeletionSafetyAllowsOnlyReleasedOrUnrelatedSessions() async throws {
        let fixture = makeFixture(repositoryFailsFinalize: true)
        let meetingID = try await fixture.coordinator.start(mode: .offline)

        let canDeleteActive = await fixture.coordinator.canDeleteMeeting(id: meetingID)
        let canDeleteUnrelated = await fixture.coordinator.canDeleteMeeting(id: UUID())
        XCTAssertFalse(canDeleteActive)
        XCTAssertTrue(canDeleteUnrelated)

        do {
            try await fixture.coordinator.stop()
            XCTFail("Expected repository finalize failure")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .repositoryFinalize)
        }

        let canDeleteReleased = await fixture.coordinator.canDeleteMeeting(id: meetingID)
        XCTAssertTrue(canDeleteReleased)
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
        for _ in 0..<100 {
            if await fixture.repository.savedTranscripts().count == 1 {
                break
            }
            await Task.yield()
        }

        let snapshot = await fixture.coordinator.snapshot()
        let transcripts = await fixture.repository.savedTranscripts()
        XCTAssertEqual(snapshot.state, .recording)
        XCTAssertEqual(transcripts.map(\.text), ["chunk-0"])
        try await fixture.coordinator.stop()
    }

    func testAudioWriteFailureStopsCaptureInsteadOfBufferingForever() async throws {
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: 16_000,
            samples: [0, 1, 2, 3]
        )
        let fixture = makeFixture(frames: [frame], writerFailsAppend: true)

        try await fixture.coordinator.start(mode: .offline)
        for _ in 0..<1_000 {
            if await fixture.events.values().contains("capture.stop") {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let events = await fixture.events.values()
        let snapshot = await fixture.coordinator.snapshot()
        XCTAssertTrue(events.contains("capture.stop"))
        XCTAssertTrue(snapshot.captureFailed)
        try await fixture.coordinator.stop()
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
        let fixture = makeFixture(repositoryFailsFinalize: true)
        let meetingID = try await fixture.coordinator.start(mode: .online)
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

    private func makeFixture(
        permissions: [CapturePermission: CapturePermissionStatus] = [
            .microphone: .authorized,
            .screenRecording: .authorized
        ],
        captureFailsToStart: Bool = false,
        frames: [CapturedAudioFrame] = [],
        packets: [CapturedAudioPacket]? = nil,
        transcriptionChunkSampleCount: Int? = nil,
        transcriberEmitsDrafts: Bool = false,
        writerFailsAppend: Bool = false,
        writerFailsFinish: Bool = false,
        writerFailsAppendTracks: Set<AudioTrack> = [],
        writerFailsFinishTracks: Set<AudioTrack> = [],
        writerFactoryFailsForTrack: AudioTrack? = nil,
        repositoryDegradationFailures: Int = 0,
        repositoryFailsFinalizingUpdate: Bool = false,
        repositoryFailsFinalize: Bool = false,
        captureSuspendsPause: Bool = false,
        speakerDiarizationEnabled: Bool = false
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
            emitsDrafts: transcriberEmitsDrafts
        )
        let repository = FakeCoordinatorRepository(
            events: events,
            degradationFailures: repositoryDegradationFailures,
            failsFinalizingUpdate: repositoryFailsFinalizingUpdate,
            failsFinalize: repositoryFailsFinalize
        )
        let panel = FakeCoordinatorPanel(events: events)
        let clock = ManualCoordinatorClock(
            date: Date(timeIntervalSince1970: 1_000),
            monotonic: 100
        )
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
            transcriptionFactory: FakeCoordinatorTranscriptionFactory(
                transcriber: transcriber
            ),
            repository: repository,
            speakerDiarizationPreference: speakerDiarizationPreference,
            panel: panel,
            clock: clock
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
            repository: repository,
            speakerDiarizationPreference: speakerDiarizationPreference,
            panel: panel,
            clock: clock
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
    let repository: FakeCoordinatorRepository
    let speakerDiarizationPreference: MutableSpeakerDiarizationPreference
    let panel: FakeCoordinatorPanel
    let clock: ManualCoordinatorClock

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

private enum CoordinatorTestError: Error, Equatable {
    case captureStart
    case repositoryUpdate
    case repositoryDegradation
    case writerAppend
    case writerFactory
    case writerFinish
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
    private let suspendsPause: Bool
    private var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    init(
        events: CoordinatorEventLog,
        failsToStart: Bool,
        packets: [CapturedAudioPacket],
        suspendsPause: Bool
    ) {
        self.events = events
        self.failsToStart = failsToStart
        self.packets = packets
        self.suspendsPause = suspendsPause
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        await events.append("capture.start")
        if failsToStart {
            throw CoordinatorTestError.captureStart
        }
        let pair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream()
        continuation = pair.continuation
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

    func isPauseSuspended() -> Bool {
        pauseContinuation != nil
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

private actor FakeCoordinatorTranscriber: MeetingTranscriptionQueueing {
    struct Chunk: Equatable, Sendable {
        let samples: [Float]
        let startingAt: TimeInterval
    }

    private let events: CoordinatorEventLog
    private let emitsDrafts: Bool
    private var receivedChunks: [Chunk] = []
    private var updateContinuation: AsyncStream<TranscriptDraft>.Continuation?
    private var updatesFinished = false

    init(events: CoordinatorEventLog, emitsDrafts: Bool) {
        self.events = events
        self.emitsDrafts = emitsDrafts
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) async {
        receivedChunks.append(Chunk(samples: samples, startingAt: startingAt))
        if emitsDrafts {
            updateContinuation?.yield(
                TranscriptDraft(
                    startTime: startingAt,
                    endTime: startingAt + Double(samples.count) / 16_000,
                    text: "chunk-\(Int(startingAt))"
                )
            )
        }
    }

    func drain() async {
        await events.append("transcriber.drain")
    }

    func transcripts() async -> [TranscriptDraft] {
        []
    }

    func updates() async -> AsyncStream<TranscriptDraft> {
        let pair = AsyncStream<TranscriptDraft>.makeStream()
        updateContinuation = pair.continuation
        return pair.stream
    }

    func finishUpdates() async {
        updateContinuation?.finish()
        updateContinuation = nil
        updatesFinished = true
    }

    func chunks() -> [Chunk] {
        receivedChunks
    }

    func didFinishUpdates() -> Bool {
        updatesFinished
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
    }

    private let events: CoordinatorEventLog
    private var remainingDegradationFailures: Int
    private let failsFinalizingUpdate: Bool
    private let failsFinalize: Bool
    private var meetings: [SavedMeeting] = []
    private var bookmarks: [TimeInterval] = []
    private var transcripts: [TranscriptDraft] = []
    private var degradationCodes: [String] = []
    private var degradationPersistenceAttempts = 0
    private var savedFinalization: Finalization?

    init(
        events: CoordinatorEventLog,
        degradationFailures: Int,
        failsFinalizingUpdate: Bool,
        failsFinalize: Bool
    ) {
        self.events = events
        remainingDegradationFailures = degradationFailures
        self.failsFinalizingUpdate = failsFinalizingUpdate
        self.failsFinalize = failsFinalize
    }

    func createMeeting(
        mode: MeetingMode,
        startedAt: Date,
        speakerDiarizationRequested: Bool
    ) async throws -> UUID {
        _ = startedAt
        await events.append("repository.create")
        let meetingID = UUID()
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
        degradationCodes.append(errorCode)
    }

    func finalizeMeeting(
        meetingID: UUID,
        endedAt: Date,
        activeDuration: TimeInterval
    ) async throws {
        if failsFinalize {
            throw CoordinatorTestError.repositoryFinalize
        }
        savedFinalization = Finalization(
            endedAt: endedAt,
            activeDuration: activeDuration
        )
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .ready
        }
        await events.append("repository.finalize")
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

    func savedDegradationCodes() -> [String] {
        degradationCodes
    }

    func degradationPersistenceAttemptCount() -> Int {
        degradationPersistenceAttempts
    }

    func finalization() -> Finalization? {
        savedFinalization
    }

    func savedMeetings() -> [SavedMeeting] {
        meetings
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

    init(date: Date, monotonic: TimeInterval) {
        currentDate = date
        currentMonotonic = monotonic
    }

    func now() async -> Date {
        currentDate
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
