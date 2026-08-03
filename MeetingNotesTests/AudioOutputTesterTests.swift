import AVFAudio
import CoreAudio
import XCTest
@testable import MeetingNotes

@MainActor
final class AudioOutputTesterTests: XCTestCase {
    func testDriverStopContractIsSynchronousOnMainActor() {
        let driver: any AudioOutputToneDriving =
            MainActorOutputToneDriverContractSpy()

        driver.stop()

        XCTAssertEqual(
            (driver as? MainActorOutputToneDriverContractSpy)?
                .stopCallCount,
            1
        )
    }

    func testMainActorPreferenceAdapterReadsLatestStoredOutputUID()
        async {
        let suiteName = "AudioOutputTesterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        let adapter = MainActorAudioOutputDevicePreferenceAdapter(
            settingsStore: settings
        )

        settings.preferredOutputDeviceID = "first-output"
        let first = await adapter.preferredOutputDeviceID()
        settings.preferredOutputDeviceID = "second-output"
        let second = await adapter.preferredOutputDeviceID()

        XCTAssertEqual(first, "first-output")
        XCTAssertEqual(second, "second-output")
    }

    func testOutputPreferenceAdapterFallsBackWithoutOverwritingStoredDevice()
        async {
        let suiteName = "AudioOutputTesterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        settings.preferredOutputDeviceID = "disconnected-output"
        let catalog = AudioDeviceCatalog(
            inputProvider: { [] },
            outputProvider: {
                [
                    AudioOutputDevice(
                        id: "builtin-output",
                        name: "Mac 扬声器",
                        isConnected: true,
                        isSystemDefault: true
                    )
                ]
            }
        )
        let adapter = MainActorAudioOutputDevicePreferenceAdapter(
            settingsStore: settings,
            deviceCatalog: catalog
        )

        let effectiveID = await adapter.preferredOutputDeviceID()

        XCTAssertEqual(effectiveID, "builtin-output")
        XCTAssertEqual(
            settings.preferredOutputDeviceID,
            "disconnected-output"
        )
    }

    func testOutputPreferenceAdapterUsesFirstUsableWhenNoDefaultIsMarked()
        async {
        let suiteName = "AudioOutputTesterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        let catalog = AudioDeviceCatalog(
            inputProvider: { [] },
            outputProvider: {
                [
                    AudioOutputDevice(
                        id: "first-usable-output",
                        name: "USB 扬声器",
                        isConnected: true,
                        isSystemDefault: false
                    )
                ]
            }
        )
        let adapter = MainActorAudioOutputDevicePreferenceAdapter(
            settingsStore: settings,
            deviceCatalog: catalog
        )

        let effectiveID = await adapter.preferredOutputDeviceID()

        XCTAssertEqual(effectiveID, "first-usable-output")
        XCTAssertNil(settings.preferredOutputDeviceID)
    }

    func testSelectedUIDResolvesAndRoutesExactDeviceID() async throws {
        let preference = OutputPreferenceStub(value: "output-uid")
        let resolver = OutputDeviceResolverStub(
            deviceIDs: ["output-uid": AudioDeviceID(42)]
        )
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: preference,
            resolver: resolver,
            driver: driver
        )

        let result = try await tester.playTestTone(duration: 0.25)

        let requestedUIDs = await resolver.requestedUIDs()
        let deviceIDs = driver.deviceIDs()
        XCTAssertEqual(requestedUIDs, ["output-uid"])
        XCTAssertEqual(deviceIDs, [AudioDeviceID(42)])
        XCTAssertTrue(result.wasScheduled)
        XCTAssertEqual(result.outputDeviceID, AudioDeviceID(42))
    }

    func testNilPreferenceUsesDedicatedEngineDefaultWithoutResolving() async throws {
        let resolver = OutputDeviceResolverStub(deviceIDs: [:])
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: nil),
            resolver: resolver,
            driver: driver
        )

        let result = try await tester.playTestTone(duration: 0.25)

        let requestedUIDs = await resolver.requestedUIDs()
        let deviceIDs = driver.deviceIDs()
        XCTAssertEqual(requestedUIDs, [])
        XCTAssertEqual(deviceIDs, [nil])
        XCTAssertNil(result.outputDeviceID)
    }

    func testMissingSelectedUIDThrowsTypedErrorWithoutScheduling() async {
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: "missing-output"),
            resolver: OutputDeviceResolverStub(deviceIDs: [:]),
            driver: driver
        )

        do {
            _ = try await tester.playTestTone(duration: 0.25)
            XCTFail("Expected selected-device-unavailable error")
        } catch let error as AudioOutputTestError {
            XCTAssertEqual(
                error,
                .selectedDeviceUnavailable(uid: "missing-output")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let playCallCount = driver.playCallCount()
        XCTAssertEqual(playCallCount, 0)
    }

    func testDurationIsCappedAtTwoSecondsAndResultReportsScheduling()
        async throws {
        let driver = OutputToneDriverSpy(scheduled: false)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: nil),
            resolver: OutputDeviceResolverStub(deviceIDs: [:]),
            driver: driver
        )

        let result = try await tester.playTestTone(duration: 30)

        let durations = driver.durations()
        XCTAssertEqual(durations, [2])
        XCTAssertEqual(
            result,
            AudioOutputTestResult(
                wasScheduled: false,
                duration: 2,
                outputDeviceID: nil
            )
        )
    }

    func testExplicitStopForwardsToIdempotentDriver() async {
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: nil),
            resolver: OutputDeviceResolverStub(deviceIDs: [:]),
            driver: driver
        )

        await tester.stop()
        await tester.stop()

        let stopCallCount = driver.stopCallCount()
        let isRunning = driver.isRunning()
        XCTAssertEqual(stopCallCount, 2)
        XCTAssertFalse(isRunning)
    }

    func testCallerCancellationStopsDriverAndDoesNotScheduleAfterCancellation()
        async {
        let driver = OutputToneDriverSpy(scheduled: true, blocksPlayback: true)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: nil),
            resolver: OutputDeviceResolverStub(deviceIDs: [:]),
            driver: driver
        )
        let task = Task {
            try await tester.playTestTone(duration: 1)
        }
        await driver.waitUntilPlayStarted()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let stopCallCount = driver.stopCallCount()
        let isRunning = driver.isRunning()
        XCTAssertGreaterThanOrEqual(stopCallCount, 1)
        XCTAssertFalse(isRunning)
    }

    func testStopWhileResolverIsBlockedPreventsDriverPlay() async {
        let resolver = ControlledOutputDeviceResolver(
            deviceIDs: ["old-output": AudioDeviceID(41)]
        )
        await resolver.block(uid: "old-output")
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: OutputPreferenceStub(value: "old-output"),
            resolver: resolver,
            driver: driver
        )
        let task = Task {
            try await tester.playTestTone(duration: 0.25)
        }
        await resolver.waitUntilStarted(uid: "old-output")

        await tester.stop()
        await resolver.resume(uid: "old-output")

        do {
            _ = try await task.value
            XCTFail("Expected stale request cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let playCallCount = driver.playCallCount()
        XCTAssertEqual(playCallCount, 0)
    }

    func testStopWhilePreferenceIsBlockedPreventsResolveAndPlay() async {
        let preference = BlockingOutputPreference(value: "old-output")
        let resolver = OutputDeviceResolverStub(
            deviceIDs: ["old-output": AudioDeviceID(41)]
        )
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: preference,
            resolver: resolver,
            driver: driver
        )
        let task = Task {
            try await tester.playTestTone(duration: 0.25)
        }
        await preference.waitUntilStarted()

        await tester.stop()
        await preference.resume()

        do {
            _ = try await task.value
            XCTFail("Expected stale request cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestedUIDs = await resolver.requestedUIDs()
        let playCallCount = driver.playCallCount()
        XCTAssertEqual(requestedUIDs, [])
        XCTAssertEqual(playCallCount, 0)
    }

    func testOlderResolverCompletingAfterNewerPlayNeverReachesDriver()
        async throws {
        let preference = SequencedOutputPreferenceStub(
            values: ["old-output", "new-output"]
        )
        let resolver = ControlledOutputDeviceResolver(
            deviceIDs: [
                "old-output": AudioDeviceID(41),
                "new-output": AudioDeviceID(42)
            ]
        )
        await resolver.block(uid: "old-output")
        let driver = OutputToneDriverSpy(scheduled: true)
        let tester = LiveAudioOutputTester(
            preference: preference,
            resolver: resolver,
            driver: driver
        )
        let oldTask = Task {
            try await tester.playTestTone(duration: 0.25)
        }
        await resolver.waitUntilStarted(uid: "old-output")

        let newResult = try await tester.playTestTone(duration: 0.25)
        await resolver.resume(uid: "old-output")

        do {
            _ = try await oldTask.value
            XCTFail("Expected old request cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let deviceIDs = driver.deviceIDs()
        XCTAssertEqual(deviceIDs, [AudioDeviceID(42)])
        XCTAssertEqual(newResult.outputDeviceID, AudioDeviceID(42))
    }

    func testCancellingOlderRequestDoesNotStopNewerTone() async {
        let preference = SequencedOutputPreferenceStub(
            values: ["old-output", "new-output"]
        )
        let resolver = ControlledOutputDeviceResolver(
            deviceIDs: [
                "old-output": AudioDeviceID(41),
                "new-output": AudioDeviceID(42)
            ]
        )
        await resolver.block(uid: "old-output")
        let driver = OutputToneDriverSpy(
            scheduled: true,
            blocksPlayback: true
        )
        let tester = LiveAudioOutputTester(
            preference: preference,
            resolver: resolver,
            driver: driver
        )
        let oldTask = Task {
            try await tester.playTestTone(duration: 0.25)
        }
        await resolver.waitUntilStarted(uid: "old-output")
        let newTask = Task {
            try await tester.playTestTone(duration: 0.25)
        }
        await driver.waitUntilPlayStarted()
        let stopCountBeforeOldCancellation = driver.stopCallCount()

        oldTask.cancel()
        await resolver.resume(uid: "old-output")

        do {
            _ = try await oldTask.value
            XCTFail("Expected old request cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let stopCountAfterOldCancellation = driver.stopCallCount()
        let isRunning = driver.isRunning()
        XCTAssertEqual(
            stopCountAfterOldCancellation,
            stopCountBeforeOldCancellation
        )
        XCTAssertTrue(isRunning)

        await tester.stop()
        do {
            _ = try await newTask.value
            XCTFail("Expected cleanup cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSineWaveBufferContainsNonzeroBoundedInMemorySamples() throws {
        let buffer = try SineWavePCMBufferFactory.makeBuffer(
            duration: 0.05,
            sampleRate: 8_000,
            frequency: 440,
            amplitude: 0.08
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = (0..<Int(buffer.frameLength)).map { channel[$0] }

        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 1, 0.080_001)
        XCTAssertEqual(buffer.format.channelCount, 1)
    }

    func testSineWaveFactoryRejectsInfiniteAndOversizedRequests() {
        XCTAssertThrowsError(
            try SineWavePCMBufferFactory.makeBuffer(
                duration: .infinity
            )
        )
        XCTAssertThrowsError(
            try SineWavePCMBufferFactory.makeBuffer(
                duration: 3,
                sampleRate: 48_000
            )
        )
    }

    func testSineWaveFactoryRejectsInvalidDurationAndSampleRate() {
        let invalidDurations: [TimeInterval] = [
            TimeInterval.nan, -.infinity, -1, 0
        ]
        for duration in invalidDurations {
            assertInvalidTone(duration: duration)
        }
        for sampleRate in [
            Double.nan, .infinity, -1, 0
        ] {
            assertInvalidTone(sampleRate: sampleRate)
        }
    }

    func testSineWaveFactoryRejectsInvalidFrequencyAndAmplitude() {
        for frequency in [
            Double.nan, .infinity, -1, 0, 24_000
        ] {
            assertInvalidTone(frequency: frequency)
        }
        for amplitude in [
            Float.nan, .infinity, -1, 0, 1.1
        ] {
            assertInvalidTone(amplitude: amplitude)
        }
    }

    func testSineWaveFactoryAcceptsMaximumBoundedFrameCount() throws {
        let buffer = try SineWavePCMBufferFactory.makeBuffer(
            duration: 2,
            sampleRate: 48_000
        )

        XCTAssertEqual(buffer.frameLength, 96_000)
    }

    func testLiveDriverUsesFreshSessionWhenReturningToDefaultRoute()
        async throws {
        let first = OutputToneSessionSpy()
        let second = OutputToneSessionSpy()
        let factory = OutputToneSessionFactoryStub(
            sessions: [first, second]
        )
        let driver = LiveAudioOutputToneDriver(sessionFactory: factory)

        _ = try await driver.playTone(
            outputDeviceID: AudioDeviceID(42),
            duration: 0.01
        )
        _ = try await driver.playTone(
            outputDeviceID: nil,
            duration: 0.01
        )

        XCTAssertEqual(factory.makeCallCount, 2)
        XCTAssertEqual(first.outputDeviceIDs, [AudioDeviceID(42)])
        XCTAssertEqual(second.outputDeviceIDs, [nil])
    }

    func testLiveDriverAlsoCapsDirectRequestsAtTwoSeconds() async throws {
        let session = OutputToneSessionSpy()
        let driver = LiveAudioOutputToneDriver(
            sessionFactory: OutputToneSessionFactoryStub(
                sessions: [session]
            )
        )

        _ = try await driver.playTone(
            outputDeviceID: nil,
            duration: 30
        )

        XCTAssertEqual(
            try XCTUnwrap(session.bufferDurations.first),
            2,
            accuracy: 0.000_001
        )
    }

    func testLiveDriverCancellationStopsBlockedSession() async {
        let session = OutputToneSessionSpy(blocksPlayback: true)
        let driver = LiveAudioOutputToneDriver(
            sessionFactory: OutputToneSessionFactoryStub(
                sessions: [session]
            )
        )
        let task = Task {
            try await driver.playTone(
                outputDeviceID: nil,
                duration: 0.1
            )
        }
        await session.waitUntilStarted()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(session.isRunning)
    }

    func testLiveSessionRoutesBeforeStartingOrScheduling() async throws {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let router = OutputUnitRouterSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: router
        )
        let task = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: AudioDeviceID(42)
            )
        }
        await controller.waitUntilScheduled(count: 1)

        XCTAssertEqual(
            events.values,
            [
                "route:42", "configure", "prepare",
                "start", "schedule", "play"
            ]
        )

        controller.fireCompletion(at: 0)
        let wasScheduled = try await task.value
        XCTAssertTrue(wasScheduled)
        XCTAssertEqual(events.values.last, "stopAndReset")
    }

    func testLiveSessionDefaultRouteSkipsRouter() async throws {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let router = OutputUnitRouterSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: router
        )
        let task = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 1)

        XCTAssertFalse(events.values.contains { $0.hasPrefix("route:") })

        controller.fireCompletion(at: 0)
        _ = try await task.value
    }

    func testLiveSessionRouteErrorCleansWithoutStartingOrScheduling() async {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let router = OutputUnitRouterSpy(
            events: events,
            error: OutputSessionTestError.route
        )
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: router
        )

        do {
            _ = try await session.play(
                buffer: makeToneBuffer(),
                outputDeviceID: AudioDeviceID(42)
            )
            XCTFail("Expected route error")
        } catch OutputSessionTestError.route {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(events.values, ["route:42", "stopAndReset"])
    }

    func testLiveSessionStartErrorCleansWithoutScheduling() async {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(
            events: events,
            startError: OutputSessionTestError.start
        )
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )

        do {
            _ = try await session.play(
                buffer: makeToneBuffer(),
                outputDeviceID: nil
            )
            XCTFail("Expected start error")
        } catch OutputSessionTestError.start {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            events.values,
            ["configure", "prepare", "start", "stopAndReset"]
        )
    }

    func testLiveSessionDuplicateCompletionResumesAndStopsOnce()
        async throws {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )
        let task = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 1)

        controller.fireCompletion(at: 0)
        controller.fireCompletion(at: 0)

        let wasScheduled = try await task.value
        XCTAssertTrue(wasScheduled)
        XCTAssertEqual(
            events.values.filter { $0 == "stopAndReset" }.count,
            1
        )
    }

    func testLiveSessionExplicitStopResumesCancellationOnce() async {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )
        let task = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 1)

        session.stop()
        controller.fireCompletion(at: 0)

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            events.values.filter { $0 == "stopAndReset" }.count,
            1
        )
    }

    func testLiveSessionCallerCancellationStopsAndResumesOnce() async {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )
        let task = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        controller.fireCompletion(at: 0)
        XCTAssertEqual(
            events.values.filter { $0 == "stopAndReset" }.count,
            1
        )
    }

    func testLiveSessionAlreadyCancelledSchedulesNothing() async {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )
        let gate = OutputSessionGate()
        let task = Task {
            await gate.wait()
            return try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: AudioDeviceID(42)
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(events.values, [])
        XCTAssertEqual(controller.scheduleCallCount, 0)
    }

    func testLiveSessionSupersedingPlayKeepsNewCompletionIsolated()
        async throws {
        let events = OutputSessionEventRecorder()
        let controller = OutputToneEngineControllerSpy(events: events)
        let session = LiveAudioOutputToneSession(
            controller: controller,
            router: OutputUnitRouterSpy(events: events)
        )
        let first = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 1)
        let second = Task {
            try await session.play(
                buffer: try makeToneBuffer(),
                outputDeviceID: nil
            )
        }
        await controller.waitUntilScheduled(count: 2)

        do {
            _ = try await first.value
            XCTFail("Expected superseded playback cancellation")
        } catch is CancellationError {
            // Expected.
        }
        controller.fireCompletion(at: 0)
        controller.fireCompletion(at: 1)

        let wasScheduled = try await second.value
        XCTAssertTrue(wasScheduled)
        XCTAssertEqual(controller.scheduleCallCount, 2)
        XCTAssertEqual(
            events.values.filter { $0 == "stopAndReset" }.count,
            2
        )
    }

    private func makeToneBuffer() throws -> AVAudioPCMBuffer {
        try SineWavePCMBufferFactory.makeBuffer(duration: 0.01)
    }

    private func assertInvalidTone(
        duration: TimeInterval = 0.05,
        sampleRate: Double = 48_000,
        frequency: Double = 440,
        amplitude: Float = 0.08,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SineWavePCMBufferFactory.makeBuffer(
                duration: duration,
                sampleRate: sampleRate,
                frequency: frequency,
                amplitude: amplitude
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AudioOutputTestError,
                .invalidToneParameters,
                file: file,
                line: line
            )
        }
    }
}

@MainActor
private final class MainActorOutputToneDriverContractSpy:
    AudioOutputToneDriving {
    private(set) var stopCallCount = 0

    func playTone(
        outputDeviceID: AudioDeviceID?,
        duration: TimeInterval
    ) async throws -> Bool {
        _ = outputDeviceID
        _ = duration
        return true
    }

    func stop() {
        stopCallCount += 1
    }
}

private enum OutputSessionTestError: Error {
    case route
    case start
}

@MainActor
private final class OutputSessionEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class OutputUnitRouterSpy: AudioOutputUnitDeviceRouting {
    private let events: OutputSessionEventRecorder
    private let error: Error?

    init(
        events: OutputSessionEventRecorder,
        error: Error? = nil
    ) {
        self.events = events
        self.error = error
    }

    func route(
        outputUnit: AudioUnit,
        to deviceID: AudioDeviceID
    ) throws {
        _ = outputUnit
        events.append("route:\(deviceID)")
        if let error {
            throw error
        }
    }
}

@MainActor
private final class OutputToneEngineControllerSpy:
    AudioOutputToneEngineControlling {
    private let events: OutputSessionEventRecorder
    private let startError: Error?
    private var completions: [@MainActor @Sendable () -> Void] = []
    private var scheduleWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    let outputUnit: AudioUnit? = AudioUnit(bitPattern: 1)
    private(set) var scheduleCallCount = 0

    init(
        events: OutputSessionEventRecorder,
        startError: Error? = nil
    ) {
        self.events = events
        self.startError = startError
    }

    func configure(format: AVAudioFormat) {
        _ = format
        events.append("configure")
    }

    func prepare() {
        events.append("prepare")
    }

    func start() throws {
        events.append("start")
        if let startError {
            throw startError
        }
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        _ = buffer
        events.append("schedule")
        scheduleCallCount += 1
        completions.append(completion)
        let ready = scheduleWaiters.filter { scheduleCallCount >= $0.0 }
        scheduleWaiters.removeAll { scheduleCallCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func play() {
        events.append("play")
    }

    func stopAndReset() {
        events.append("stopAndReset")
    }

    func waitUntilScheduled(count: Int) async {
        if scheduleCallCount >= count { return }
        await withCheckedContinuation {
            scheduleWaiters.append((count, $0))
        }
    }

    func fireCompletion(at index: Int) {
        completions[index]()
    }
}

private actor OutputSessionGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class OutputToneSessionFactoryStub:
    AudioOutputToneSessionCreating {
    private var sessions: [OutputToneSessionSpy]
    private(set) var makeCallCount = 0

    init(sessions: [OutputToneSessionSpy]) {
        self.sessions = sessions
    }

    func makeSession() -> any AudioOutputToneSession {
        makeCallCount += 1
        return sessions.removeFirst()
    }
}

@MainActor
private final class OutputToneSessionSpy: AudioOutputToneSession {
    private let blocksPlayback: Bool
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Bool, Error>?
    private(set) var outputDeviceIDs: [AudioDeviceID?] = []
    private(set) var bufferDurations: [TimeInterval] = []
    private(set) var stopCallCount = 0
    private(set) var isRunning = false

    init(blocksPlayback: Bool = false) {
        self.blocksPlayback = blocksPlayback
    }

    func play(
        buffer: AVAudioPCMBuffer,
        outputDeviceID: AudioDeviceID?
    ) async throws -> Bool {
        _ = buffer
        outputDeviceIDs.append(outputDeviceID)
        bufferDurations.append(
            Double(buffer.frameLength) / buffer.format.sampleRate
        )
        isRunning = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        guard blocksPlayback else {
            isRunning = false
            return true
        }
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func stop() {
        guard isRunning else { return }
        stopCallCount += 1
        isRunning = false
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        if isRunning { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
}

private actor OutputPreferenceStub: AudioOutputDevicePreferenceReading {
    private let value: String?

    init(value: String?) {
        self.value = value
    }

    func preferredOutputDeviceID() async -> String? {
        value
    }
}

private actor BlockingOutputPreference:
    AudioOutputDevicePreferenceReading {
    private let value: String?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(value: String?) {
        self.value = value
    }

    func preferredOutputDeviceID() async -> String? {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return value
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SequencedOutputPreferenceStub:
    AudioOutputDevicePreferenceReading {
    private var values: [String?]

    init(values: [String?]) {
        self.values = values
    }

    func preferredOutputDeviceID() async -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor ControlledOutputDeviceResolver:
    AudioOutputDeviceIDResolving {
    private let deviceIDsByUID: [String: AudioDeviceID]
    private var blockedUIDs: Set<String> = []
    private var startedUIDs: Set<String> = []
    private var startedWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]
    private var continuations:
        [String: CheckedContinuation<Void, Never>] = [:]

    init(deviceIDs: [String: AudioDeviceID]) {
        deviceIDsByUID = deviceIDs
    }

    func block(uid: String) {
        blockedUIDs.insert(uid)
    }

    func deviceID(forUID uid: String) async throws -> AudioDeviceID? {
        startedUIDs.insert(uid)
        startedWaiters.removeValue(forKey: uid)?.forEach { $0.resume() }
        if blockedUIDs.contains(uid) {
            await withCheckedContinuation {
                continuations[uid] = $0
            }
        }
        return deviceIDsByUID[uid]
    }

    func waitUntilStarted(uid: String) async {
        if startedUIDs.contains(uid) { return }
        await withCheckedContinuation {
            startedWaiters[uid, default: []].append($0)
        }
    }

    func resume(uid: String) {
        blockedUIDs.remove(uid)
        continuations.removeValue(forKey: uid)?.resume()
    }
}

private actor OutputDeviceResolverStub: AudioOutputDeviceIDResolving {
    private let deviceIDsByUID: [String: AudioDeviceID]
    private var UIDs: [String] = []

    init(deviceIDs: [String: AudioDeviceID]) {
        deviceIDsByUID = deviceIDs
    }

    func deviceID(forUID uid: String) async throws -> AudioDeviceID? {
        UIDs.append(uid)
        return deviceIDsByUID[uid]
    }

    func requestedUIDs() -> [String] {
        UIDs
    }
}

@MainActor
private final class OutputToneDriverSpy: AudioOutputToneDriving {
    private let scheduled: Bool
    private let blocksPlayback: Bool
    private var requestedDeviceIDs: [AudioDeviceID?] = []
    private var requestedDurations: [TimeInterval] = []
    private var stops = 0
    private var running = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var playbackContinuation: CheckedContinuation<Bool, Error>?

    init(scheduled: Bool, blocksPlayback: Bool = false) {
        self.scheduled = scheduled
        self.blocksPlayback = blocksPlayback
    }

    func playTone(
        outputDeviceID: AudioDeviceID?,
        duration: TimeInterval
    ) async throws -> Bool {
        requestedDeviceIDs.append(outputDeviceID)
        requestedDurations.append(duration)
        running = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        guard blocksPlayback else {
            running = false
            return scheduled
        }
        return try await withCheckedThrowingContinuation { continuation in
            playbackContinuation = continuation
        }
    }

    func stop() {
        stops += 1
        running = false
        playbackContinuation?.resume(throwing: CancellationError())
        playbackContinuation = nil
    }

    func waitUntilPlayStarted() async {
        if running { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func deviceIDs() -> [AudioDeviceID?] {
        requestedDeviceIDs
    }

    func durations() -> [TimeInterval] {
        requestedDurations
    }

    func playCallCount() -> Int {
        requestedDurations.count
    }

    func stopCallCount() -> Int {
        stops
    }

    func isRunning() -> Bool {
        running
    }
}
