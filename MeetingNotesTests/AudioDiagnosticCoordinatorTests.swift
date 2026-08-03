import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import MeetingNotes

final class AudioDiagnosticCoordinatorTests: XCTestCase {
    func testPrepareChecksAvailabilityAndPlaysToneBeforeAwaitingConfirmation()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()

        let state = await coordinator.state
        XCTAssertEqual(state, .awaitingOutputConfirmation)
        XCTAssertEqual(
            events.values,
            ["recording", "permissions", "inputDevice", "tone"]
        )
    }

    func testConfirmedToneMeasuresBothTracksAndProducesHealthyReport()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            systemAudioTester: SystemSignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(heardTone: true)

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected readyForUpload, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .captureHealthy)
        XCTAssertEqual(report.facts.microphoneMetrics, audibleMetrics())
        XCTAssertEqual(report.facts.systemAudioMetrics, audibleMetrics())
        XCTAssertEqual(report.facts.userHeardOutputTone, true)
        XCTAssertEqual(
            events.values,
            [
                "recording",
                "permissions",
                "inputDevice",
                "tone",
                "microphone:3.0",
                "systemStarted",
                "tone",
                "system:3.0",
                "outputStop",
                "microphoneCancel",
                "systemCancel"
            ]
        )
    }

    func testPrepareRejectsWhileMeetingRecordingIsActive() async {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: true,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        do {
            try await coordinator.prepare()
            XCTFail("Expected recordingActive")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .recordingActive
            )
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .failed("recordingActive"))
        XCTAssertEqual(events.values, ["recording"])
    }

    func testDeniedPermissionsSkipCapturesAndStillProduceIssueReport()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .denied,
                    screenRecording: .denied
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            systemAudioTester: SystemSignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(heardTone: true)

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .microphonePermissionDenied)
        XCTAssertEqual(report.supportingIssues, [.screenPermissionDenied])
        XCTAssertNil(report.facts.microphoneMetrics)
        XCTAssertNil(report.facts.systemAudioMetrics)
        XCTAssertEqual(
            events.values,
            [
                "recording",
                "permissions",
                "inputDevice",
                "tone",
                "outputStop",
                "microphoneCancel",
                "systemCancel"
            ]
        )
    }

    func testUnavailableInputSkipsMicrophoneButStillTestsSystemAudio()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: false,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            systemAudioTester: SystemSignalTesterStub(
                metrics: audibleMetrics(),
                events: events
            ),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(heardTone: true)

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .inputDeviceUnavailable)
        XCTAssertNil(report.facts.microphoneMetrics)
        XCTAssertEqual(report.facts.systemAudioMetrics, audibleMetrics())
        XCTAssertEqual(
            events.values,
            [
                "recording",
                "permissions",
                "inputDevice",
                "tone",
                "systemStarted",
                "tone",
                "system:3.0",
                "outputStop",
                "microphoneCancel",
                "systemCancel"
            ]
        )
    }

    func testContinueFromIdleThrowsTypedInvalidState() async {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        do {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
            XCTFail("Expected invalidState")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .invalidState(.idle)
            )
        }
        XCTAssertTrue(events.values.isEmpty)
    }

    func testNilRuleResultFailsWithInsufficientEvidence() async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            ruleEngine: NilRuleEngine(),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        try await coordinator.prepare()

        do {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
            XCTFail("Expected insufficientEvidence")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .insufficientEvidence
            )
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .failed("insufficientEvidence"))
    }

    func testTimeoutFailsAndCleansEveryResourceExactlyOnce() async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(events: events),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ThrowingTimeoutRacer()
        )
        try await coordinator.prepare()

        do {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut
            )
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .failed("timedOut"))
        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testCallerCancellationCleansEveryResourceExactlyOnce()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let microphone = BlockingSignalTester(events: events)
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: microphone,
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        try await coordinator.prepare()
        let task = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await microphone.waitUntilStarted()

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .failed("cancelled"))
        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testSuccessfulRunCleansEveryResourceExactlyOnce() async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(events: events),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(heardTone: true)

        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testCoordinatorCancelIsIdempotentDuringActiveTest()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let microphone = BlockingSignalTester(events: events)
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: microphone,
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        try await coordinator.prepare()
        let task = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await microphone.waitUntilStarted()

        await coordinator.cancel()
        await coordinator.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .failed("cancelled"))
        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testDependencyFailureCleansResourcesAndTransitionsToFailed()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                ),
                events: events
            ),
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: FailingSignalTester(events: events),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        do {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
            XCTFail("Expected dependency failure")
        } catch {
            XCTAssertEqual(error as? AudioDiagnosticTestFailure, .failed)
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .failed("failed"))
        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testLiveMicrophoneTesterUsesPreferenceAccumulatesAndStops()
        async throws {
        let buffer = try makePCMBuffer(
            samples: Array(repeating: 0.1, count: 3_000),
            sampleRate: 1_000
        )
        let provider = MicrophoneSampleProviderStub(buffers: [buffer])
        let preference = AudioInputPreferenceStub(
            deviceID: "selected-microphone"
        )
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: preference
        )

        let metrics = try await tester.testSignal(duration: 3)
        await tester.cancel()

        XCTAssertEqual(metrics.sampleCount, 3_000)
        XCTAssertEqual(metrics.observationDuration, 3, accuracy: 0.000_001)
        XCTAssertEqual(metrics.level, .audible)
        let deviceIDs = await provider.startedDeviceIDs
        let stopCount = await provider.stopCount
        XCTAssertEqual(deviceIDs, ["selected-microphone"])
        XCTAssertEqual(stopCount, 1)
    }

    func testLiveMicrophoneTesterReturnsNoFramesWhenWindowEndsWithoutCallbacks()
        async throws {
        let provider = BlockingMicrophoneSampleProvider()
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: AudioInputPreferenceStub(deviceID: nil),
            observationSleeper: ImmediateTimeoutSleeper()
        )

        let metrics = try await tester.testSignal(duration: 3)

        XCTAssertEqual(metrics.sampleCount, 0)
        XCTAssertEqual(metrics.level, .noFrames)
        let stopCount = await provider.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testLiveMicrophoneTesterCancelStopsActiveProviderExactlyOnce()
        async {
        let provider = BlockingMicrophoneSampleProvider()
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: AudioInputPreferenceStub(deviceID: nil)
        )
        let task = Task {
            try await tester.testSignal(duration: 3)
        }
        await provider.waitUntilStarted()

        await tester.cancel()
        await tester.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stopCount = await provider.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testLiveSystemTesterUsesAudioOnlyConfigurationAndStopsSession()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let session = SystemAudioSessionStub(events: events)
        let factory = SystemAudioSessionFactoryStub(session: session)
        let tester = LiveSystemAudioDiagnosticSignalTester(factory: factory)

        let metrics = try await tester.testSignal(duration: 3) {
            events.append("tone")
        }
        await tester.cancel()

        let capturedConfiguration = await factory.configuration
        let configuration = try XCTUnwrap(capturedConfiguration)
        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertFalse(configuration.capturesMicrophone)
        XCTAssertFalse(configuration.excludesCurrentProcessAudio)
        XCTAssertFalse(configuration.excludesCurrentApplication)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 1)
        XCTAssertEqual(metrics, audibleMetrics())
        let cancelCount = await session.cancelCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(
            events.values,
            ["sessionStarted", "tone", "sessionMeasured", "sessionCancel"]
        )
    }

    func testDiagnosticStreamConfigurationDoesNotAlterProductionCapturePolicy() {
        let diagnosticConfiguration =
            AudioDiagnosticSystemCaptureConfiguration()
        let diagnostic = diagnosticConfiguration.makeStreamConfiguration()
        let production = ScreenAudioCaptureConfiguration
            .makeStreamConfiguration(microphoneDeviceID: nil)

        XCTAssertTrue(diagnostic.capturesAudio)
        XCTAssertFalse(diagnostic.captureMicrophone)
        XCTAssertFalse(diagnostic.excludesCurrentProcessAudio)
        XCTAssertTrue(
            diagnosticConfiguration.excludedApplicationBundleIdentifiers(
                currentBundleIdentifier: "com.shenminghao.MeetingNotes"
            ).isEmpty
        )
        XCTAssertTrue(production.excludesCurrentProcessAudio)
    }

    func testScreenCaptureKitFactoryDefersHardwareAccessUntilSessionRuns()
        async throws {
        let factory = ScreenCaptureKitAudioDiagnosticSessionFactory()

        let session = try await factory.makeSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration()
        )

        XCTAssertTrue(
            session is ScreenCaptureKitAudioDiagnosticSession
        )
        await session.cancel()
    }

    func testMicrophoneCancelWhilePreferenceSuspendedNeverStartsProvider()
        async {
        let preference = SuspendingAudioInputPreference()
        let provider = CountingMicrophoneSampleProvider()
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: preference
        )
        let task = Task {
            try await tester.testSignal(duration: 3)
        }
        await preference.waitUntilReadStarts()

        await tester.cancel()
        await preference.resume(with: "late-device")

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let startCount = await provider.startCount
        let stopCount = await provider.stopCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 0)
    }

    func testConcurrentMicrophoneTestCannotPassSuspendedStart()
        async {
        let provider = FirstStartSuspendingMicrophoneProvider()
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: AudioInputPreferenceStub(deviceID: nil)
        )
        let first = Task {
            try await tester.testSignal(duration: 3)
        }
        await provider.waitUntilFirstStartBegins()

        do {
            _ = try await tester.testSignal(duration: 3)
            XCTFail("Expected alreadyRunning")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticLiveSignalError,
                .alreadyRunning
            )
        }

        await provider.resumeFirstStart()
        _ = try? await first.value
        let startCount = await provider.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testCancelledMicrophoneRunCannotStopReplacementRun() async {
        let preference = FirstReadSuspendingAudioInputPreference()
        let provider = BlockingMicrophoneSampleProvider()
        let tester = LiveMicrophoneAudioDiagnosticSignalTester(
            provider: provider,
            inputPreference: preference
        )
        let first = Task {
            try await tester.testSignal(duration: 3)
        }
        await preference.waitUntilFirstReadBegins()
        await tester.cancel()

        let replacement = Task {
            try await tester.testSignal(duration: 3)
        }
        await provider.waitUntilStarted()
        await preference.resumeFirst(with: "stale-device")
        _ = try? await first.value

        let stopCountBeforeReplacementCancellation = await provider.stopCount
        XCTAssertEqual(stopCountBeforeReplacementCancellation, 0)

        await tester.cancel()
        _ = try? await replacement.value
    }

    func testScreenSessionStartsThenCallbacksMeasuresAndStops()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let runtime = ScreenCaptureRuntimeStub(events: events)
        let session = ScreenCaptureKitAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(),
            runtime: runtime
        )

        let metrics = try await session.testSignal(duration: 3) {
            events.append("tone")
        }

        XCTAssertEqual(metrics, audibleMetrics())
        let stopCount = await runtime.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(
            events.values,
            ["runtimeStart", "tone", "runtimeMeasure:3.0", "runtimeStop"]
        )
    }

    func testScreenSessionStartFailureStillStopsExactlyOnce() async {
        let runtime = FailingScreenCaptureRuntime()
        let session = ScreenCaptureKitAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(),
            runtime: runtime
        )

        do {
            _ = try await session.testSignal(duration: 3) {}
            XCTFail("Expected setup failure")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticLiveSignalError,
                .screenCaptureSetupFailed
            )
        }
        await session.cancel()
        let stopCount = await runtime.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testScreenSessionCancelDuringSuspendedStartIsIdempotent()
        async {
        let runtime = SuspendingScreenCaptureRuntime()
        let session = ScreenCaptureKitAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(),
            runtime: runtime
        )
        let task = Task {
            try await session.testSignal(duration: 3) {}
        }
        await runtime.waitUntilStartBegins()

        await session.cancel()
        await session.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let measureCount = await runtime.measureCount
        let stopCount = await runtime.stopCount
        XCTAssertEqual(measureCount, 0)
        XCTAssertEqual(stopCount, 1)
    }

    func testLiveTimeoutRacerReturnsOperationWithoutWaitingForClock()
        async throws {
        let sleeper = AwaitingTimeoutSleeper()
        let racer = LiveAudioDiagnosticTimeoutRacer(sleeper: sleeper)

        let metrics = try await racer.run(timeout: 4) {
            await sleeper.waitUntilStarted()
            return audibleMetrics()
        }

        XCTAssertEqual(metrics, audibleMetrics())
    }

    func testLiveTimeoutRacerThrowsTypedTimeoutWithoutSleeping() async {
        let pair = AsyncThrowingStream<
            AudioSignalMetrics,
            Error
        >.makeStream()
        defer { pair.continuation.finish() }
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ImmediateTimeoutSleeper()
        )

        do {
            _ = try await racer.run(timeout: 4) {
                for try await metrics in pair.stream {
                    return metrics
                }
                throw CancellationError()
            }
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut
            )
        }
    }

    func testConcurrentSystemTestCannotPassSuspendedFactory() async {
        let factory = FirstFactorySuspendingSystemSessionFactory()
        let tester = LiveSystemAudioDiagnosticSignalTester(factory: factory)
        let first = Task {
            try await tester.testSignal(duration: 3) {}
        }
        await factory.waitUntilFirstMakeBegins()

        do {
            _ = try await tester.testSignal(duration: 3) {}
            XCTFail("Expected alreadyRunning")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticLiveSignalError,
                .alreadyRunning
            )
        }

        await factory.resumeFirstMake()
        _ = try? await first.value
        let makeCount = await factory.makeCount
        XCTAssertEqual(makeCount, 1)
    }

    func testCancelledSystemRunCannotCancelReplacementSession() async {
        let factory = FirstFactorySuspendingThenBlockingSessionFactory()
        let tester = LiveSystemAudioDiagnosticSignalTester(factory: factory)
        let first = Task {
            try await tester.testSignal(duration: 3) {}
        }
        await factory.waitUntilFirstMakeBegins()
        await tester.cancel()

        let replacement = Task {
            try await tester.testSignal(duration: 3) {}
        }
        await factory.waitUntilReplacementSessionStarts()
        await factory.resumeFirstMake()
        _ = try? await first.value

        let replacementCancelCount = await factory.replacementCancelCount()
        XCTAssertEqual(replacementCancelCount, 0)

        await tester.cancel()
        _ = try? await replacement.value
    }
}

private final class AudioDiagnosticEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    func count(of value: String) -> Int {
        lock.withLock { storage.filter { $0 == value }.count }
    }
}

private struct RecordingActivityStub: AudioDiagnosticRecordingActivityChecking {
    let isActive: Bool
    let events: AudioDiagnosticEventRecorder

    func isRecordingActive() async -> Bool {
        events.append("recording")
        return isActive
    }
}

private struct PermissionSnapshotStub: AudioDiagnosticPermissionChecking {
    let snapshot: AudioDiagnosticPermissionSnapshot
    let events: AudioDiagnosticEventRecorder

    func permissionSnapshot() async -> AudioDiagnosticPermissionSnapshot {
        events.append("permissions")
        return snapshot
    }
}

private struct InputDeviceAvailabilityStub:
    AudioDiagnosticInputDeviceChecking {
    let isAvailable: Bool
    let events: AudioDiagnosticEventRecorder

    func inputDeviceIsAvailable() async -> Bool {
        events.append("inputDevice")
        return isAvailable
    }
}

private struct OutputTesterStub: AudioOutputTesting {
    let events: AudioDiagnosticEventRecorder

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        events.append("tone")
        return AudioOutputTestResult(
            wasScheduled: true,
            duration: duration,
            outputDeviceID: nil
        )
    }

    func stop() async {
        events.append("outputStop")
    }
}

private struct SignalTesterStub: AudioDiagnosticSignalTesting {
    var metrics = audibleMetrics()
    var events: AudioDiagnosticEventRecorder?

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        events?.append("microphone:\(duration)")
        return metrics
    }

    func cancel() async {
        events?.append("microphoneCancel")
    }
}

private enum AudioDiagnosticTestFailure: Error {
    case failed
}

private struct FailingSignalTester: AudioDiagnosticSignalTesting {
    let events: AudioDiagnosticEventRecorder

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        throw AudioDiagnosticTestFailure.failed
    }

    func cancel() async {
        events.append("microphoneCancel")
    }
}

private struct SystemSignalTesterStub: AudioDiagnosticSystemSignalTesting {
    var metrics = audibleMetrics()
    var events: AudioDiagnosticEventRecorder?

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        events?.append("systemStarted")
        try await afterCaptureStarts()
        events?.append("system:\(duration)")
        return metrics
    }

    func cancel() async {
        events?.append("systemCancel")
    }
}

private func audibleMetrics() -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 144_000,
        rms: 0.1,
        peak: 0.2,
        observationDuration: 3,
        sampleRate: 48_000,
        channelCount: 1,
        level: .audible
    )
}

private struct ImmediateTimeoutRacer: AudioDiagnosticTimeoutRacing {
    func run(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics {
        try await operation()
    }
}

private struct ThrowingTimeoutRacer: AudioDiagnosticTimeoutRacing {
    func run(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics {
        throw AudioDiagnosticCoordinatorError.timedOut
    }
}

private actor BlockingSignalTester: AudioDiagnosticSignalTesting {
    private let events: AudioDiagnosticEventRecorder
    private let started = AudioDiagnosticTestSignal()
    private var continuation:
        CheckedContinuation<AudioSignalMetrics, Error>?

    init(events: AudioDiagnosticEventRecorder) {
        self.events = events
    }

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        events.append("microphone:\(duration)")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { await started.signal() }
            }
        } onCancel: {
            Task { await self.releaseForCancellation() }
        }
    }

    func cancel() async {
        events.append("microphoneCancel")
        releaseForCancellation()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    private func releaseForCancellation() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor AudioDiagnosticTestSignal {
    private var hasSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !hasSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        hasSignaled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor MicrophoneSampleProviderStub: MicrophoneSampleProviding {
    private let buffers: [AVAudioPCMBuffer]
    private(set) var startedDeviceIDs: [String?] = []
    private(set) var stopCount = 0

    init(buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
    }

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        startedDeviceIDs.append(deviceID)
        let buffers = buffers
        return AsyncThrowingStream { continuation in
            for buffer in buffers {
                continuation.yield(
                    MicrophoneSample(
                        buffer: buffer,
                        sampleTime: 0,
                        sampleRate: buffer.format.sampleRate
                    )
                )
            }
            continuation.finish()
        }
    }

    func pause() async throws {}
    func resume() async throws {}

    func stop() async {
        stopCount += 1
    }
}

private actor AudioInputPreferenceStub:
    AudioInputDevicePreferenceReading {
    private let deviceID: String?

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    func preferredInputDeviceID() async -> String? {
        deviceID
    }
}

private actor BlockingMicrophoneSampleProvider:
    MicrophoneSampleProviding {
    private let started = AudioDiagnosticTestSignal()
    private var continuation:
        AsyncThrowingStream<MicrophoneSample, Error>.Continuation?
    private(set) var stopCount = 0

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        _ = deviceID
        let pair = AsyncThrowingStream<MicrophoneSample, Error>.makeStream()
        continuation = pair.continuation
        await started.signal()
        return pair.stream
    }

    func pause() async throws {}
    func resume() async throws {}

    func stop() async {
        guard continuation != nil else { return }
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func waitUntilStarted() async {
        await started.wait()
    }
}

private actor SuspendingAudioInputPreference:
    AudioInputDevicePreferenceReading {
    private let started = AudioDiagnosticTestSignal()
    private var continuation: CheckedContinuation<String?, Never>?

    func preferredInputDeviceID() async -> String? {
        await started.signal()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReadStarts() async {
        await started.wait()
    }

    func resume(with deviceID: String?) {
        continuation?.resume(returning: deviceID)
        continuation = nil
    }
}

private actor FirstReadSuspendingAudioInputPreference:
    AudioInputDevicePreferenceReading {
    private let firstStarted = AudioDiagnosticTestSignal()
    private var firstContinuation: CheckedContinuation<String?, Never>?
    private var readCount = 0

    func preferredInputDeviceID() async -> String? {
        readCount += 1
        guard readCount == 1 else { return "replacement-device" }
        await firstStarted.signal()
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func waitUntilFirstReadBegins() async {
        await firstStarted.wait()
    }

    func resumeFirst(with deviceID: String?) {
        firstContinuation?.resume(returning: deviceID)
        firstContinuation = nil
    }
}

private actor CountingMicrophoneSampleProvider:
    MicrophoneSampleProviding {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        _ = deviceID
        startCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async { stopCount += 1 }
}

private actor FirstStartSuspendingMicrophoneProvider:
    MicrophoneSampleProviding {
    private let firstStarted = AudioDiagnosticTestSignal()
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        _ = deviceID
        startCount += 1
        if startCount == 1 {
            await firstStarted.signal()
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async {}

    func waitUntilFirstStartBegins() async {
        await firstStarted.wait()
    }

    func resumeFirstStart() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor SystemAudioSessionFactoryStub:
    AudioDiagnosticSystemAudioSessionCreating {
    private let session: SystemAudioSessionStub
    private(set) var configuration:
        AudioDiagnosticSystemCaptureConfiguration?

    init(session: SystemAudioSessionStub) {
        self.session = session
    }

    func makeSession(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws -> any AudioDiagnosticSystemAudioSession {
        self.configuration = configuration
        return session
    }
}

private actor SystemAudioSessionStub: AudioDiagnosticSystemAudioSession {
    private let events: AudioDiagnosticEventRecorder
    private(set) var cancelCount = 0

    init(events: AudioDiagnosticEventRecorder) {
        self.events = events
    }

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        XCTAssertEqual(duration, 3)
        events.append("sessionStarted")
        try await afterCaptureStarts()
        events.append("sessionMeasured")
        return audibleMetrics()
    }

    func cancel() async {
        cancelCount += 1
        events.append("sessionCancel")
    }
}

private actor FirstFactorySuspendingSystemSessionFactory:
    AudioDiagnosticSystemAudioSessionCreating {
    private let firstStarted = AudioDiagnosticTestSignal()
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var makeCount = 0

    func makeSession(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws -> any AudioDiagnosticSystemAudioSession {
        _ = configuration
        makeCount += 1
        if makeCount == 1 {
            await firstStarted.signal()
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return SystemAudioSessionStub(
            events: AudioDiagnosticEventRecorder()
        )
    }

    func waitUntilFirstMakeBegins() async {
        await firstStarted.wait()
    }

    func resumeFirstMake() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor FirstFactorySuspendingThenBlockingSessionFactory:
    AudioDiagnosticSystemAudioSessionCreating {
    private let firstStarted = AudioDiagnosticTestSignal()
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var makeCount = 0
    private let replacement = BlockingSystemAudioSession()

    func makeSession(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws -> any AudioDiagnosticSystemAudioSession {
        _ = configuration
        makeCount += 1
        if makeCount == 1 {
            await firstStarted.signal()
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
            return SystemAudioSessionStub(
                events: AudioDiagnosticEventRecorder()
            )
        }
        return replacement
    }

    func waitUntilFirstMakeBegins() async {
        await firstStarted.wait()
    }

    func waitUntilReplacementSessionStarts() async {
        await replacement.waitUntilStarted()
    }

    func resumeFirstMake() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func replacementCancelCount() async -> Int {
        await replacement.cancelCount
    }
}

private actor BlockingSystemAudioSession:
    AudioDiagnosticSystemAudioSession {
    private let started = AudioDiagnosticTestSignal()
    private var continuation:
        CheckedContinuation<AudioSignalMetrics, Error>?
    private(set) var cancelCount = 0

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        _ = duration
        try await afterCaptureStarts()
        await started.signal()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        await started.wait()
    }
}

private actor ScreenCaptureRuntimeStub:
    AudioDiagnosticScreenCaptureRuntime {
    private let events: AudioDiagnosticEventRecorder
    private(set) var stopCount = 0

    init(events: AudioDiagnosticEventRecorder) {
        self.events = events
    }

    func start(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws {
        XCTAssertTrue(configuration.capturesAudio)
        events.append("runtimeStart")
    }

    func measureSignal(duration: TimeInterval) async throws
        -> AudioSignalMetrics {
        events.append("runtimeMeasure:\(duration)")
        return audibleMetrics()
    }

    func stop() async {
        stopCount += 1
        events.append("runtimeStop")
    }
}

private actor FailingScreenCaptureRuntime:
    AudioDiagnosticScreenCaptureRuntime {
    private(set) var stopCount = 0

    func start(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws {
        _ = configuration
        throw AudioDiagnosticLiveSignalError.screenCaptureSetupFailed
    }

    func measureSignal(duration: TimeInterval) async throws
        -> AudioSignalMetrics {
        fatalError("Must not measure after failed start")
    }

    func stop() async {
        stopCount += 1
    }
}

private actor SuspendingScreenCaptureRuntime:
    AudioDiagnosticScreenCaptureRuntime {
    private let started = AudioDiagnosticTestSignal()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var measureCount = 0
    private(set) var stopCount = 0

    func start(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws {
        _ = configuration
        await started.signal()
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func measureSignal(duration: TimeInterval) async throws
        -> AudioSignalMetrics {
        _ = duration
        measureCount += 1
        return audibleMetrics()
    }

    func stop() async {
        guard stopCount == 0 else { return }
        stopCount = 1
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStartBegins() async {
        await started.wait()
    }
}

private struct ImmediateTimeoutSleeper:
    AudioDiagnosticTimeoutSleeping {
    func sleep(for duration: TimeInterval) async throws {
        _ = duration
    }
}

private actor AwaitingTimeoutSleeper:
    AudioDiagnosticTimeoutSleeping {
    private let started = AudioDiagnosticTestSignal()

    func sleep(for duration: TimeInterval) async throws {
        _ = duration
        let pair = AsyncStream<Void>.makeStream()
        await started.signal()
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        await started.wait()
    }
}

private func makePCMBuffer(
    samples: [Float],
    sampleRate: Double
) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
    )
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let destination = try XCTUnwrap(buffer.floatChannelData?[0])
    destination.update(from: samples, count: samples.count)
    return buffer
}

private struct NilRuleEngine: AudioDiagnosticRuleEvaluating {
    func evaluate(_ facts: AudioDiagnosticFacts) -> AudioDiagnosticReport? {
        nil
    }
}
