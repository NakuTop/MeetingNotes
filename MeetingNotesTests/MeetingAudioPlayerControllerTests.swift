import AVFoundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingAudioPlayerControllerTests: XCTestCase {
    func testAudioIsReadyAndPlayableBeforeBlockedWaveformFinishes() async {
        let meetingID = UUID()
        let waveformLoader = ControlledWaveformLoader(
            values: [meetingID: [0.2, 0.8]]
        )
        await waveformLoader.block(meetingID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: ControlledAudioSourceLoader(
                sources: [
                    meetingID: makeSource(
                        meetingID: meetingID,
                        duration: 14
                    )
                ]
            ),
            waveformLoader: waveformLoader,
            engine: engine
        )

        let preparation = Task {
            await controller.prepare(meetingID: meetingID)
        }
        await waveformLoader.waitUntilStarted(meetingID)

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 14, accuracy: 0.000_001)
        XCTAssertTrue(controller.waveform.isEmpty)
        controller.togglePlayback()
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.playCallCount, 1)

        await waveformLoader.resume(meetingID)
        await preparation.value
        XCTAssertEqual(controller.waveform, [0.2, 0.8])
    }

    func testPrepareTransitionsFromLoadingToReadyWithSourceDurationAndWaveform() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 12)]
        )
        await sourceLoader.block(meetingID)
        let waveformLoader = ControlledWaveformLoader(
            values: [meetingID: [0.1, 0.7, 0.4]]
        )
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: waveformLoader,
            engine: engine
        )

        let preparation = Task { await controller.prepare(meetingID: meetingID) }
        await sourceLoader.waitUntilStarted(meetingID)

        XCTAssertEqual(controller.state, .loading)
        XCTAssertEqual(controller.meetingID, meetingID)
        XCTAssertEqual(controller.currentTime, 0)

        await sourceLoader.resume(meetingID)
        await preparation.value

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 12, accuracy: 0.000_001)
        XCTAssertEqual(controller.waveform, [0.1, 0.7, 0.4])
        XCTAssertEqual(engine.preparedMeetingIDs, [meetingID])
    }

    func testAudioPrepareFailureBecomesReadableChineseFailure() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        engine.prepareErrors[meetingID] = PlaybackTestError.audioPrepare
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID)],
            engine: engine
        )

        await controller.prepare(meetingID: meetingID)

        guard case let .failed(message) = controller.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(message, "无法准备会议录音，请稍后重试。")
        XCTAssertEqual(controller.duration, 0)
        XCTAssertTrue(controller.waveform.isEmpty)
    }

    func testWaveformFailureStillLeavesAudioReadyWithEmptyWaveform() async {
        let meetingID = UUID()
        let waveformLoader = ControlledWaveformLoader()
        await waveformLoader.setError(PlaybackTestError.waveform, for: meetingID)
        let controller = makeController(
            sourceLoader: ControlledAudioSourceLoader(
                sources: [meetingID: makeSource(meetingID: meetingID, duration: 8)]
            ),
            waveformLoader: waveformLoader
        )

        await controller.prepare(meetingID: meetingID)

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 8, accuracy: 0.000_001)
        XCTAssertEqual(controller.waveform, [])
    }

    func testPlayPauseAndPeriodicUpdatesPreserveAndClampCurrentTime() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 10)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)

        controller.togglePlayback()
        engine.emitTime(4.25, for: meetingID)
        controller.togglePlayback()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.currentTime, 4.25, accuracy: 0.000_001)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.pauseCallCount, 1)

        engine.emitTime(-3, for: meetingID)
        XCTAssertEqual(controller.currentTime, 0)
        engine.emitTime(30, for: meetingID)
        XCTAssertEqual(controller.currentTime, 10)
        engine.emitTime(.nan, for: meetingID)
        XCTAssertEqual(controller.currentTime, 0)
    }

    func testEndCallbackAndEndedToggleRestartFromZero() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 9)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)
        controller.togglePlayback()

        engine.emitEnd(for: meetingID)

        XCTAssertEqual(controller.state, .ended)
        XCTAssertEqual(controller.currentTime, 9, accuracy: 0.000_001)

        controller.togglePlayback()

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(engine.seekTimes, [0])
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testSeekFractionsClampNaNInfinityAndOutOfRangeValues() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 20)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)

        let cases: [(fraction: Double, expected: Double)] = [
            (Double.nan, 0),
            (-Double.infinity, 0),
            (-1, 0),
            (0.25, 5),
            (2, 20),
            (Double.infinity, 20)
        ]
        for (fraction, expected) in cases {
            controller.beginSeeking(to: fraction)
            controller.endSeeking(at: fraction)
            XCTAssertEqual(controller.currentTime, expected, accuracy: 0.000_001)
        }

        XCTAssertEqual(engine.seekTimes, [0, 0, 0, 5, 20, 20])
    }

    func testSeekingOnlyPreviewsUntilEndIgnoresTicksAndRestoresPlayIntention() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 40)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)
        controller.togglePlayback()

        controller.beginSeeking(to: 0.25)
        controller.updateSeeking(to: 0.5)
        engine.emitTime(2, for: meetingID)

        XCTAssertEqual(controller.currentTime, 20, accuracy: 0.000_001)
        XCTAssertTrue(engine.seekTimes.isEmpty)
        XCTAssertEqual(engine.pauseCallCount, 1)

        controller.endSeeking(at: 0.75)

        XCTAssertEqual(engine.seekTimes, [30])
        XCTAssertEqual(engine.playCallCount, 2)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentTime, 30, accuracy: 0.000_001)
    }

    func testSeekingFromPausedStateDoesNotResumeAndStopClearsSeekState() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 10)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)
        controller.togglePlayback()
        controller.togglePlayback()

        controller.beginSeeking(to: 0.4)
        controller.endSeeking(at: 0.6)

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.seekTimes, [6])

        controller.beginSeeking(to: 0.8)
        controller.stop(meetingID: meetingID)
        controller.endSeeking(at: 0.9)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.meetingID)
        XCTAssertEqual(engine.seekTimes, [6])
    }

    func testPreparingAnotherMeetingStopsOldAndLateSourceCannotOverwriteNew() async {
        let firstID = UUID()
        let secondID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(sources: [
            firstID: makeSource(meetingID: firstID, duration: 100),
            secondID: makeSource(meetingID: secondID, duration: 6)
        ])
        await sourceLoader.block(firstID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(values: [secondID: [0.5]]),
            engine: engine
        )

        let first = Task { await controller.prepare(meetingID: firstID) }
        await sourceLoader.waitUntilStarted(firstID)
        await controller.prepare(meetingID: secondID)

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 6, accuracy: 0.000_001)
        XCTAssertEqual(engine.stopCallCount, 1)

        await sourceLoader.resume(firstID)
        await first.value

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.duration, 6, accuracy: 0.000_001)
        XCTAssertEqual(engine.preparedMeetingIDs, [secondID])
    }

    func testLateEngineReturnAndCallbackCannotOverwriteNewMeeting() async {
        let firstID = UUID()
        let secondID = UUID()
        let engine = PlaybackEngineSpy()
        engine.blockedPrepareMeetingIDs = [firstID]
        let controller = makeController(
            sources: [
                firstID: makeSource(meetingID: firstID, duration: 100),
                secondID: makeSource(meetingID: secondID, duration: 7)
            ],
            engine: engine
        )

        let first = Task { await controller.prepare(meetingID: firstID) }
        await engine.waitUntilPrepareStarted(for: firstID)
        await controller.prepare(meetingID: secondID)
        engine.resumePrepare(for: firstID)
        await first.value
        engine.emitTime(88, for: firstID)
        engine.emitEnd(for: firstID)

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 7, accuracy: 0.000_001)
        XCTAssertEqual(controller.currentTime, 0)
    }

    func testLateWaveformCannotOverwriteNewMeeting() async {
        let firstID = UUID()
        let secondID = UUID()
        let waveformLoader = ControlledWaveformLoader(values: [
            firstID: [0.9],
            secondID: [0.2, 0.4]
        ])
        await waveformLoader.block(firstID)
        let controller = makeController(
            sourceLoader: ControlledAudioSourceLoader(sources: [
                firstID: makeSource(meetingID: firstID, duration: 30),
                secondID: makeSource(meetingID: secondID, duration: 4)
            ]),
            waveformLoader: waveformLoader
        )

        let first = Task { await controller.prepare(meetingID: firstID) }
        await waveformLoader.waitUntilStarted(firstID)
        await controller.prepare(meetingID: secondID)
        await waveformLoader.resume(firstID)
        await first.value

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.waveform, [0.2, 0.4])
        XCTAssertEqual(controller.duration, 4, accuracy: 0.000_001)
    }

    func testRepeatedPrepareForSameReadyMeetingIsIdempotent() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID)]
        )
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(),
            engine: engine
        )

        await controller.prepare(meetingID: meetingID)
        await controller.prepare(meetingID: meetingID)

        let sourceLoadCount = await sourceLoader.loadCount(for: meetingID)
        XCTAssertEqual(sourceLoadCount, 1)
        XCTAssertEqual(engine.preparedMeetingIDs, [meetingID])
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testCancellingOneOfTwoSharedPrepareWaitersKeepsPreparationAlive() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 11)]
        )
        await sourceLoader.block(meetingID)
        let waveformLoader = ControlledWaveformLoader(
            values: [meetingID: [0.2, 0.8]]
        )
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: waveformLoader,
            engine: engine
        )

        let first = Task { await controller.prepare(meetingID: meetingID) }
        await sourceLoader.waitUntilStarted(meetingID)
        let second = Task { await controller.prepare(meetingID: meetingID) }
        await Task.yield()

        first.cancel()
        await Task.yield()

        XCTAssertEqual(controller.state, .loading)
        XCTAssertEqual(controller.meetingID, meetingID)
        XCTAssertEqual(engine.stopCallCount, 0)

        await sourceLoader.resume(meetingID)
        await first.value
        await second.value

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 11, accuracy: 0.000_001)
        XCTAssertEqual(controller.waveform, [0.2, 0.8])
        let sourceLoadCount = await sourceLoader.loadCount(for: meetingID)
        XCTAssertEqual(sourceLoadCount, 1)
        XCTAssertEqual(engine.preparedMeetingIDs, [meetingID])
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testCancellingEverySharedPrepareWaiterCancelsAndResetsPreparation() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 11)]
        )
        await sourceLoader.block(meetingID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(),
            engine: engine
        )

        let first = Task { await controller.prepare(meetingID: meetingID) }
        await sourceLoader.waitUntilStarted(meetingID)
        let second = Task { await controller.prepare(meetingID: meetingID) }
        await Task.yield()

        first.cancel()
        second.cancel()
        await Task.yield()
        await Task.yield()

        assertIdle(controller)
        XCTAssertEqual(engine.stopCallCount, 1)

        await sourceLoader.resume(meetingID)
        await first.value
        await second.value

        assertIdle(controller)
        XCTAssertTrue(engine.preparedMeetingIDs.isEmpty)

        await controller.prepare(meetingID: meetingID)

        XCTAssertEqual(controller.state, .ready)
        let sourceLoadCount = await sourceLoader.loadCount(for: meetingID)
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(engine.preparedMeetingIDs, [meetingID])
    }

    func testFailedPreparationClearsSharedWaitersAndCanBeRetried() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 13)]
        )
        let engine = PlaybackEngineSpy()
        engine.prepareErrors[meetingID] = PlaybackTestError.audioPrepare
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(),
            engine: engine
        )

        await controller.prepare(meetingID: meetingID)
        guard case .failed = controller.state else {
            return XCTFail("Expected first preparation to fail")
        }

        engine.prepareErrors[meetingID] = nil
        await controller.prepare(meetingID: meetingID)

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 13, accuracy: 0.000_001)
        let sourceLoadCount = await sourceLoader.loadCount(for: meetingID)
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(engine.preparedMeetingIDs, [meetingID, meetingID])
    }

    func testStopIgnoresUnrelatedMeetingAndMatchingOrNilStopFullyReset() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 5)],
            waveformValues: [meetingID: [0.3]],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)

        controller.stop(meetingID: UUID())
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(engine.stopCallCount, 0)

        controller.stop(meetingID: meetingID)
        assertIdle(controller)
        XCTAssertEqual(engine.stopCallCount, 1)

        await controller.prepare(meetingID: meetingID)
        controller.stop()
        assertIdle(controller)
        XCTAssertEqual(engine.stopCallCount, 2)
    }

    func testStopCancelsLoadingAndIgnoresAllLateResultsAndCallbacks() async {
        let meetingID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(
            sources: [meetingID: makeSource(meetingID: meetingID, duration: 50)]
        )
        await sourceLoader.block(meetingID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(),
            engine: engine
        )

        let preparation = Task { await controller.prepare(meetingID: meetingID) }
        await sourceLoader.waitUntilStarted(meetingID)
        controller.stop(meetingID: meetingID)
        await sourceLoader.resume(meetingID)
        await preparation.value
        engine.emitTime(40, for: meetingID)
        engine.emitEnd(for: meetingID)

        assertIdle(controller)
        XCTAssertTrue(engine.preparedMeetingIDs.isEmpty)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testStopAndWaitResetsImmediatelyButWaitsForPreparationToQuiesce() async {
        let meetingID = UUID()
        let waveformLoader = ControlledWaveformLoader()
        await waveformLoader.block(meetingID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: ControlledAudioSourceLoader(
                sources: [meetingID: makeSource(meetingID: meetingID)]
            ),
            waveformLoader: waveformLoader,
            engine: engine
        )
        let completion = AsyncCompletionFlag()

        let preparation = Task {
            await controller.prepare(meetingID: meetingID)
        }
        await waveformLoader.waitUntilStarted(meetingID)
        let shutdown = Task {
            await controller.stopAndWait(meetingID: meetingID)
            await completion.markCompleted()
        }
        await Task.yield()

        assertIdle(controller)
        XCTAssertEqual(engine.stopCallCount, 1)
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await waveformLoader.resume(meetingID)
        await preparation.value
        await shutdown.value

        let completedAfterRelease = await completion.isCompleted()
        XCTAssertTrue(completedAfterRelease)
        assertIdle(controller)
    }

    func testStopAndWaitForUnrelatedMeetingIsImmediateNoOp() async {
        let meetingID = UUID()
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sources: [meetingID: makeSource(meetingID: meetingID)],
            engine: engine
        )
        await controller.prepare(meetingID: meetingID)

        await controller.stopAndWait(meetingID: UUID())

        XCTAssertEqual(controller.meetingID, meetingID)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testStopAndWaitJoinsPreparationAlreadyCancelledBySynchronousStop() async {
        let meetingID = UUID()
        let waveformLoader = ControlledWaveformLoader()
        await waveformLoader.block(meetingID)
        let controller = makeController(
            sourceLoader: ControlledAudioSourceLoader(
                sources: [meetingID: makeSource(meetingID: meetingID)]
            ),
            waveformLoader: waveformLoader
        )
        let completion = AsyncCompletionFlag()

        let preparation = Task {
            await controller.prepare(meetingID: meetingID)
        }
        await waveformLoader.waitUntilStarted(meetingID)
        controller.stop(meetingID: meetingID)
        let shutdown = Task {
            await controller.stopAndWait(meetingID: meetingID)
            await completion.markCompleted()
        }
        await Task.yield()

        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await waveformLoader.resume(meetingID)
        await preparation.value
        await shutdown.value

        let completedAfterRelease = await completion.isCompleted()
        XCTAssertTrue(completedAfterRelease)
        assertIdle(controller)
    }

    func testLateCancelledWaiterCannotStopNewGeneration() async {
        let firstID = UUID()
        let secondID = UUID()
        let sourceLoader = ControlledAudioSourceLoader(sources: [
            firstID: makeSource(meetingID: firstID, duration: 20),
            secondID: makeSource(meetingID: secondID, duration: 7)
        ])
        await sourceLoader.block(firstID)
        let engine = PlaybackEngineSpy()
        let controller = makeController(
            sourceLoader: sourceLoader,
            waveformLoader: ControlledWaveformLoader(),
            engine: engine
        )

        let first = Task { await controller.prepare(meetingID: firstID) }
        await sourceLoader.waitUntilStarted(firstID)
        first.cancel()
        controller.stop(meetingID: firstID)
        await controller.prepare(meetingID: secondID)
        let oldShutdown = Task {
            await controller.stopAndWait(meetingID: firstID)
        }
        await Task.yield()

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.duration, 7, accuracy: 0.000_001)

        await sourceLoader.resume(firstID)
        await first.value
        await oldShutdown.value

        XCTAssertEqual(controller.meetingID, secondID)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testLiveCompositionContainsEveryRealCAFSegmentInOrder() async throws {
        let fixture = try await makeCAFSource(
            segments: [[0.1, 0.2], [0.3, 0.4, 0.5], [0.6]]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let composition = try await AVFoundationMeetingAudioPlaybackEngine
            .makeComposition(for: fixture.source)
        let track = try XCTUnwrap(composition.tracks(withMediaType: .audio).first)

        XCTAssertEqual(track.segments.count, 3)
        XCTAssertEqual(
            track.segments.map(\.timeMapping.target.start.seconds),
            [0, 2.0 / 16_000.0, 5.0 / 16_000.0]
        )
        XCTAssertEqual(
            composition.duration.seconds,
            6.0 / 16_000.0,
            accuracy: 0.000_000_1
        )
    }

    func testLiveEngineLatePreparationCannotReplaceOrStopNewItem() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstComposition = AVMutableComposition()
        let secondComposition = AVMutableComposition()
        let builder = ControlledCompositionBuilder(compositions: [
            firstID: firstComposition,
            secondID: secondComposition
        ])
        builder.block(firstID)
        let player = AVPlayer()
        let engine = AVFoundationMeetingAudioPlaybackEngine(
            player: player,
            compositionBuilder: { source in
                try await builder.build(for: source)
            }
        )

        let first = Task {
            try await engine.prepare(
                source: makeSource(meetingID: firstID),
                onPeriodicTime: { _ in },
                onEnd: {}
            )
        }
        await builder.waitUntilStarted(firstID)

        _ = try await engine.prepare(
            source: makeSource(meetingID: secondID),
            onPeriodicTime: { _ in },
            onEnd: {}
        )
        XCTAssertTrue(player.currentItem?.asset === secondComposition)

        builder.resume(firstID)
        do {
            _ = try await first.value
            XCTFail("Expected stale preparation cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(player.currentItem?.asset === secondComposition)
    }

    func testLiveEngineEndObserverFiltersOldItemsAndIsRemovedOnStop() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstComposition = AVMutableComposition()
        let secondComposition = AVMutableComposition()
        let builder = ControlledCompositionBuilder(compositions: [
            firstID: firstComposition,
            secondID: secondComposition
        ])
        let player = AVPlayer()
        let recorder = EndCallbackRecorder()
        let engine = AVFoundationMeetingAudioPlaybackEngine(
            player: player,
            compositionBuilder: { source in
                try await builder.build(for: source)
            }
        )

        _ = try await engine.prepare(
            source: makeSource(meetingID: firstID),
            onPeriodicTime: { _ in },
            onEnd: { recorder.recordFirst() }
        )
        let firstItem = try XCTUnwrap(player.currentItem)
        _ = try await engine.prepare(
            source: makeSource(meetingID: secondID),
            onPeriodicTime: { _ in },
            onEnd: { recorder.recordSecond() }
        )
        let secondItem = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: firstItem
        )
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: AVPlayerItem(asset: AVMutableComposition())
        )
        await Task.yield()
        XCTAssertEqual(recorder.firstCount, 0)
        XCTAssertEqual(recorder.secondCount, 0)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: secondItem
        )
        await Task.yield()
        XCTAssertEqual(recorder.secondCount, 1)

        engine.stop()
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: secondItem
        )
        await Task.yield()
        XCTAssertEqual(recorder.secondCount, 1)
    }

    private func makeController(
        sources: [UUID: MeetingAudioSource],
        waveformValues: [UUID: [Float]] = [:],
        engine: PlaybackEngineSpy = PlaybackEngineSpy()
    ) -> MeetingAudioPlayerController {
        makeController(
            sourceLoader: ControlledAudioSourceLoader(sources: sources),
            waveformLoader: ControlledWaveformLoader(values: waveformValues),
            engine: engine
        )
    }

    private func makeController(
        sourceLoader: ControlledAudioSourceLoader,
        waveformLoader: ControlledWaveformLoader,
        engine: PlaybackEngineSpy = PlaybackEngineSpy()
    ) -> MeetingAudioPlayerController {
        MeetingAudioPlayerController(
            sourceLoader: sourceLoader,
            waveformLoader: waveformLoader,
            engine: engine,
            waveformBucketCount: 120
        )
    }

    private func makeSource(
        meetingID: UUID,
        duration: TimeInterval = 10
    ) -> MeetingAudioSource {
        MeetingAudioSource(
            meetingID: meetingID,
            resolvedSegments: [],
            segmentFrameCounts: [Int64(duration * 16_000)],
            sampleRate: 16_000,
            channelCount: 1,
            totalFrames: Int64(duration * 16_000),
            manifestSignature: "manifest-\(meetingID)",
            identitySignature: "identity-\(meetingID)"
        )
    }

    private func assertIdle(
        _ controller: MeetingAudioPlayerController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(controller.meetingID, file: file, line: line)
        XCTAssertEqual(controller.state, .idle, file: file, line: line)
        XCTAssertEqual(controller.currentTime, 0, file: file, line: line)
        XCTAssertEqual(controller.duration, 0, file: file, line: line)
        XCTAssertEqual(controller.waveform, [], file: file, line: line)
    }

    private func makeCAFSource(
        segments: [[Float]]
    ) async throws -> (root: URL, source: MeetingAudioSource) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioPlayerTests-\(UUID().uuidString)")
        let meetingID = UUID()
        let fileStore = MeetingFileStore(rootURL: root)
        let directory = try await fileStore.prepareMeetingDirectory(for: meetingID)
        var manifestSegments: [AudioSegmentManifest.Segment] = []
        var frameCursor: Int64 = 0

        for (index, samples) in segments.enumerated() {
            let fileName = String(format: "segment-%04d.caf", index + 1)
            try writeCAF(samples: samples, to: directory.appendingPathComponent(fileName))
            let start = Double(frameCursor) / 16_000
            frameCursor += Int64(samples.count)
            manifestSegments.append(.init(
                fileName: fileName,
                startTime: start,
                endTime: Double(frameCursor) / 16_000,
                frameCount: Int64(samples.count),
                isComplete: true
            ))
        }
        try await fileStore.saveManifest(
            AudioSegmentManifest(segments: manifestSegments),
            meetingID: meetingID
        )
        let source = try await MeetingAudioSourceLoader(fileStore: fileStore)
            .load(meetingID: meetingID)
        return (root, source)
    }

    private func writeCAF(samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
        file.close()
    }
}

private enum PlaybackTestError: Error {
    case audioPrepare
    case waveform
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

@MainActor
private final class EndCallbackRecorder {
    private(set) var firstCount = 0
    private(set) var secondCount = 0

    func recordFirst() {
        firstCount += 1
    }

    func recordSecond() {
        secondCount += 1
    }
}

@MainActor
private final class ControlledCompositionBuilder {
    private let compositions: [UUID: AVMutableComposition]
    private var blockedIDs: Set<UUID> = []
    private var startedIDs: Set<UUID> = []
    private var startedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var resumeContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(compositions: [UUID: AVMutableComposition]) {
        self.compositions = compositions
    }

    func block(_ meetingID: UUID) {
        blockedIDs.insert(meetingID)
    }

    func build(for source: MeetingAudioSource) async throws -> AVMutableComposition {
        let meetingID = source.meetingID
        startedIDs.insert(meetingID)
        startedWaiters.removeValue(forKey: meetingID)?.forEach { $0.resume() }
        if blockedIDs.contains(meetingID) {
            await withCheckedContinuation { continuation in
                resumeContinuations[meetingID] = continuation
            }
        }
        return try XCTUnwrap(compositions[meetingID])
    }

    func waitUntilStarted(_ meetingID: UUID) async {
        if startedIDs.contains(meetingID) { return }
        await withCheckedContinuation { continuation in
            startedWaiters[meetingID, default: []].append(continuation)
        }
    }

    func resume(_ meetingID: UUID) {
        blockedIDs.remove(meetingID)
        resumeContinuations.removeValue(forKey: meetingID)?.resume()
    }
}

private actor ControlledAudioSourceLoader: MeetingAudioSourceLoading {
    private let sources: [UUID: MeetingAudioSource]
    private var blockedIDs: Set<UUID> = []
    private var startedIDs: Set<UUID> = []
    private var startedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var resumeContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var counts: [UUID: Int] = [:]

    init(sources: [UUID: MeetingAudioSource]) {
        self.sources = sources
    }

    func block(_ meetingID: UUID) {
        blockedIDs.insert(meetingID)
    }

    func load(meetingID: UUID) async throws -> MeetingAudioSource {
        counts[meetingID, default: 0] += 1
        startedIDs.insert(meetingID)
        startedWaiters.removeValue(forKey: meetingID)?.forEach { $0.resume() }
        if blockedIDs.contains(meetingID) {
            await withCheckedContinuation { continuation in
                resumeContinuations[meetingID] = continuation
            }
        }
        guard let source = sources[meetingID] else {
            throw MeetingAudioSourceLoaderError.manifestNotFound
        }
        return source
    }

    func waitUntilStarted(_ meetingID: UUID) async {
        if startedIDs.contains(meetingID) { return }
        await withCheckedContinuation { continuation in
            startedWaiters[meetingID, default: []].append(continuation)
        }
    }

    func resume(_ meetingID: UUID) {
        blockedIDs.remove(meetingID)
        resumeContinuations.removeValue(forKey: meetingID)?.resume()
    }

    func loadCount(for meetingID: UUID) -> Int {
        counts[meetingID, default: 0]
    }
}

private actor ControlledWaveformLoader: MeetingWaveformLoading {
    private var valuesByMeeting: [UUID: [Float]]
    private var errors: [UUID: Error] = [:]
    private var blockedIDs: Set<UUID> = []
    private var startedIDs: Set<UUID> = []
    private var startedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var resumeContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(values: [UUID: [Float]] = [:]) {
        valuesByMeeting = values
    }

    func block(_ meetingID: UUID) {
        blockedIDs.insert(meetingID)
    }

    func setError(_ error: Error, for meetingID: UUID) {
        errors[meetingID] = error
    }

    func values(
        for source: MeetingAudioSource,
        bucketCount: Int
    ) async throws -> [Float] {
        _ = bucketCount
        let meetingID = source.meetingID
        startedIDs.insert(meetingID)
        startedWaiters.removeValue(forKey: meetingID)?.forEach { $0.resume() }
        if blockedIDs.contains(meetingID) {
            await withCheckedContinuation { continuation in
                resumeContinuations[meetingID] = continuation
            }
        }
        if let error = errors[meetingID] { throw error }
        return valuesByMeeting[meetingID, default: []]
    }

    func waitUntilStarted(_ meetingID: UUID) async {
        if startedIDs.contains(meetingID) { return }
        await withCheckedContinuation { continuation in
            startedWaiters[meetingID, default: []].append(continuation)
        }
    }

    func resume(_ meetingID: UUID) {
        blockedIDs.remove(meetingID)
        resumeContinuations.removeValue(forKey: meetingID)?.resume()
    }
}

@MainActor
private final class PlaybackEngineSpy: MeetingAudioPlaybackEngine {
    var prepareErrors: [UUID: Error] = [:]
    var blockedPrepareMeetingIDs: Set<UUID> = []
    private var prepareContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var prepareStarted: Set<UUID> = []
    private var prepareWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var timeCallbacks: [UUID: @MainActor (TimeInterval) -> Void] = [:]
    private var endCallbacks: [UUID: @MainActor () -> Void] = [:]
    private(set) var preparedMeetingIDs: [UUID] = []
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekTimes: [TimeInterval] = []
    private(set) var stopCallCount = 0

    func prepare(
        source: MeetingAudioSource,
        onPeriodicTime: @escaping @MainActor (TimeInterval) -> Void,
        onEnd: @escaping @MainActor () -> Void
    ) async throws -> TimeInterval {
        let meetingID = source.meetingID
        preparedMeetingIDs.append(meetingID)
        timeCallbacks[meetingID] = onPeriodicTime
        endCallbacks[meetingID] = onEnd
        prepareStarted.insert(meetingID)
        prepareWaiters.removeValue(forKey: meetingID)?.forEach { $0.resume() }
        if blockedPrepareMeetingIDs.contains(meetingID) {
            await withCheckedContinuation { continuation in
                prepareContinuations[meetingID] = continuation
            }
        }
        if let error = prepareErrors[meetingID] { throw error }
        return source.duration
    }

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }
    func seek(to time: TimeInterval) { seekTimes.append(time) }
    func stop() { stopCallCount += 1 }

    func emitTime(_ time: TimeInterval, for meetingID: UUID) {
        timeCallbacks[meetingID]?(time)
    }

    func emitEnd(for meetingID: UUID) {
        endCallbacks[meetingID]?()
    }

    func waitUntilPrepareStarted(for meetingID: UUID) async {
        if prepareStarted.contains(meetingID) { return }
        await withCheckedContinuation { continuation in
            prepareWaiters[meetingID, default: []].append(continuation)
        }
    }

    func resumePrepare(for meetingID: UUID) {
        blockedPrepareMeetingIDs.remove(meetingID)
        prepareContinuations.removeValue(forKey: meetingID)?.resume()
    }
}
