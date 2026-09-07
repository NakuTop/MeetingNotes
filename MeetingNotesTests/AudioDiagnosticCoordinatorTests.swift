import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class AudioDiagnosticCoordinatorTests: XCTestCase {
    func testLiveDiagnosticDoesNotProbeScreenPermissionAndTestsActualSystemAudio() async throws {
        let events = AudioDiagnosticEventRecorder()
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            screenPreflight: { events.append("screenPreflight"); return false },
            screenProbe: { events.append("screenProbe"); return .denied }
        )
        let permissions = LiveAudioDiagnosticPermissionChecker(system: system)
        let snapshot = await permissions.permissionSnapshot()
        XCTAssertEqual(snapshot.microphone, .authorized)
        XCTAssertNil(snapshot.screenRecording, "Screen authorization is not an audio-tap preflight")
        XCTAssertTrue(events.values.isEmpty)
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: permissions,
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(heardTone: true)
        guard case let .readyForUpload(report) = await coordinator.state else {
            return XCTFail("Expected actual system-audio evidence")
        }
        XCTAssertEqual(report.primaryIssue, .captureHealthy)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.systemAudioMetrics, audibleMetrics())
        XCTAssertNil(report.facts.screenPermission)
        XCTAssertFalse(events.values.contains("screenProbe"))
    }

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

    func testCancelledPreparationCannotPlayToneOrPublishAwaitingState()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let permissions = SuspendingPermissionSnapshotStub(
            snapshot: AudioDiagnosticPermissionSnapshot(
                microphone: .authorized,
                screenRecording: .authorized
            ),
            events: events
        )
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(
                isActive: false,
                events: events
            ),
            permissions: permissions,
            inputDevice: InputDeviceAvailabilityStub(
                isAvailable: true,
                events: events
            ),
            outputTester: OutputTesterStub(events: events),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        let caller = Task {
            try await coordinator.prepare()
        }
        await permissions.waitUntilRequested()

        caller.cancel()
        await coordinator.cancel()
        await permissions.release()

        do {
            try await caller.value
            XCTFail("Expected cancelled preparation")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Expected CancellationError, got \(error)"
            )
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .failed("cancelled"))
        XCTAssertEqual(events.count(of: "tone"), 0)
        XCTAssertEqual(events.count(of: "inputDevice"), 0)
    }

    func testCancelDuringToneStopsAndCompletesPreparationWithoutManualRelease()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let output = SuspendingOutputTester(events: events)
        let callerFinished = expectation(description: "caller finished")
        let callerFinishedSignal = AudioDiagnosticGateTestSignal()
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
            outputTester: output,
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )
        let caller = Task { () -> Bool in
            defer {
                callerFinishedSignal.signal()
                callerFinished.fulfill()
            }
            do {
                try await coordinator.prepare()
                return false
            } catch {
                return error is CancellationError
            }
        }
        await output.waitUntilPlayStarted()

        caller.cancel()
        await coordinator.cancel()
        await fulfillment(of: [callerFinished], timeout: 0.5)

        if !callerFinishedSignal.isSignaled {
            await output.releaseToneForTestTeardown()
        }
        let callerWasCancelled = await caller.value
        XCTAssertTrue(callerWasCancelled)
        let state = await coordinator.state
        XCTAssertEqual(state, .failed("cancelled"))
        XCTAssertEqual(events.count(of: "tone"), 1)
        XCTAssertEqual(events.count(of: "outputStop"), 1)
    }

    func testPreparationToneFailureTransitionsToCoherentFailedState()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let output = FailingPreparationOutputTester(events: events)
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: output,
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        do {
            try await coordinator.prepare()
            XCTFail("Expected tone failure")
        } catch {
            XCTAssertTrue(error is AudioDiagnosticTestFailure)
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .failed("outputToneFailed"))
        XCTAssertEqual(events.count(of: "tone"), 1)
        XCTAssertEqual(events.count(of: "outputStop"), 1)
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

        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected report after timeout, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .timedOut)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .notRun)
        XCTAssertEqual(events.count(of: "outputStop"), 1)
        XCTAssertEqual(events.count(of: "microphoneCancel"), 1)
        XCTAssertEqual(events.count(of: "systemCancel"), 1)
    }

    func testSmartMicrophoneHealthyWithSlowStartupPassesUnderNewBudget()
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
            microphoneTester: SlowStartupSignalTester(
                simulatedStartup: 2,
                scale: 0.05
            ),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.05)
            )
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected healthy report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .captureHealthy)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .succeeded)
    }

    func testOldFourSecondBudgetWouldTimeoutSlowMicrophoneStartup()
        async throws {
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ScaledTimeoutSleeper(scale: 0.05)
        )
        let operation: @Sendable () async throws -> AudioSignalMetrics = {
            try await Task.sleep(
                nanoseconds: UInt64((5.0 * 0.05 * 1_000_000_000).rounded())
            )
            return audibleMetrics()
        }

        do {
            _ = try await racer.run(
                stage: .microphone,
                timeout: 4,
                operation: operation
            )
            XCTFail("Expected the old 4s budget to time out")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut(.microphone)
            )
        }

        let metrics = try await racer.run(
            stage: .microphone,
            timeout: 12,
            operation: operation
        )
        XCTAssertEqual(metrics, audibleMetrics())
    }

    func testSmartSystemAudioHealthyWithSlowSetupPassesUnderNewBudget()
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
            microphoneTester: SignalTesterStub(events: events),
            systemAudioTester: SlowSystemAudioStartupTester(
                simulatedSetup: 1.25,
                scale: 0.05
            ),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.05)
            )
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected healthy report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .captureHealthy)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .succeeded)
    }

    func testOldFourSecondBudgetWouldTimeoutSlowSystemAudioSetup()
        async throws {
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ScaledTimeoutSleeper(scale: 0.05)
        )
        let operation: @Sendable () async throws -> AudioSignalMetrics = {
            try await Task.sleep(
                nanoseconds: UInt64(
                    (4.25 * 0.05 * 1_000_000_000).rounded()
                )
            )
            return audibleMetrics()
        }

        do {
            _ = try await racer.run(
                stage: .systemAudio,
                timeout: 4,
                operation: operation
            )
            XCTFail("Expected the old 4s budget to time out")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut(.systemAudio)
            )
        }

        let metrics = try await racer.run(
            stage: .systemAudio,
            timeout: 15,
            operation: operation
        )
        XCTAssertEqual(metrics, audibleMetrics())
    }

    func testMicrophoneDiagnosticStillTimesOutWhenOperationExceedsBudget()
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
            microphoneTester: SlowStartupSignalTester(
                simulatedStartup: 13,
                scale: 0.01
            ),
            systemAudioTester: SystemSignalTesterStub(events: events),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01)
            )
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected timeout report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .timedOut)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .notRun)
    }

    func testSystemAudioDiagnosticStillTimesOutWhenOperationExceedsBudget()
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
            microphoneTester: SignalTesterStub(events: events),
            systemAudioTester: SlowSystemAudioStartupTester(
                simulatedSetup: 16,
                scale: 0.01
            ),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01)
            )
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected timeout report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .systemAudioDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.microphoneMetrics, audibleMetrics())
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .timedOut)
        XCTAssertNil(report.facts.systemAudioMetrics)
    }

    func testMicrophoneTimeoutProducesUploadableDiagnosticReport()
        async throws {
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: SignalTesterStub(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ThrowingTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected uploadable report, got \(state)")
        }
        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: report,
            metadata: AudioDiagnosticUploadMetadata(
                appVersion: "1.2.0",
                hardwareModel: "Mac",
                macOSVersion: "26",
                inputDevice: .init(name: "Mic", status: .selected),
                outputDevice: .init(name: "Speaker", status: .automatic),
                apiErrorCategory: nil
            )
        )
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .timedOut)
        XCTAssertEqual(envelope.primaryIssueCode, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(envelope.microphoneTestOutcome, .timedOut)
        XCTAssertEqual(envelope.diagnosticFailureStage, .microphone)
    }

    func testSystemAudioTimeoutPreservesSuccessfulMicrophoneEvidence()
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
            microphoneTester: SignalTesterStub(metrics: audibleMetrics()),
            systemAudioTester: SlowSystemAudioStartupTester(
                simulatedSetup: 16,
                scale: 0.01
            ),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01)
            )
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected uploadable report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .systemAudioDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.microphoneMetrics, audibleMetrics())
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .timedOut)
        XCTAssertNil(report.facts.systemAudioMetrics)

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: report,
            metadata: AudioDiagnosticUploadMetadata(
                appVersion: "1.2.0",
                hardwareModel: "Mac",
                macOSVersion: "26",
                inputDevice: .init(name: "Mic", status: .selected),
                outputDevice: .init(name: "Speaker", status: .automatic),
                apiErrorCategory: nil
            )
        )
        XCTAssertEqual(envelope.microphoneTestOutcome, .succeeded)
        XCTAssertNotNil(envelope.microphoneMetrics)
        XCTAssertEqual(envelope.systemAudioTestOutcome, .timedOut)
        XCTAssertEqual(envelope.diagnosticFailureStage, .systemAudio)
    }

    func testMicrophoneTestFailureCreatesUploadableReportWithoutRawError()
        async throws {
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: FailingSignalTester(),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected uploadable report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticFailed)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .failed)
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .notRun)

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: report,
            metadata: AudioDiagnosticUploadMetadata(
                appVersion: "1.2.0",
                hardwareModel: "Mac",
                macOSVersion: "26",
                inputDevice: .init(name: "Mic", status: .selected),
                outputDevice: .init(name: "Speaker", status: .automatic),
                apiErrorCategory: nil
            )
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(envelope),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("AudioDiagnosticTestFailure"))
    }

    func testSystemAudioTestFailureCreatesUploadableReportAfterMicrophone()
        async throws {
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: SignalTesterStub(metrics: audibleMetrics()),
            systemAudioTester: FailingSystemSignalTester(),
            timeoutRacer: ImmediateTimeoutRacer()
        )

        try await coordinator.prepare()
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected uploadable report, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .systemAudioDiagnosticFailed)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(report.facts.microphoneMetrics, audibleMetrics())
        XCTAssertEqual(report.facts.systemAudioTestOutcome, .failed)
    }

    func testTimeoutReturnsPromptlyForNonCooperativeOperation()
        async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let racer = LiveAudioDiagnosticTimeoutRacer()
        let startedAt = Date()
        let task = Task {
            try await racer.run(
                stage: .microphone,
                timeout: 0.1
            ) {
                try await operation.run()
            }
        }
        await operation.waitUntilStarted()

        do {
            _ = try await task.value
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut(.microphone)
            )
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "timeout returned after \(elapsed)s"
        )
        await operation.releaseSuccess()
    }

    func testLateSuccessAfterTimeoutDoesNotReplaceTimeoutReport()
        async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let lateTerminalAttempted = AudioDiagnosticGateTestSignal()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: NonCooperativeMicrophoneSignalTester(
                operation: operation
            ),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01),
                gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                    operationTerminalAttempted: {
                        lateTerminalAttempted.signal()
                    }
                )
            )
        )
        try await coordinator.prepare()
        let diagnosticTask = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await operation.waitUntilStarted()
        _ = try? await diagnosticTask.value

        let stateBeforeRelease = await coordinator.state
        guard case let .readyForUpload(timeoutReport) = stateBeforeRelease else {
            return XCTFail("Expected timeout report, got \(stateBeforeRelease)")
        }
        XCTAssertEqual(timeoutReport.primaryIssue, .microphoneDiagnosticTimedOut)

        await operation.releaseSuccess()
        await lateTerminalAttempted.wait()

        let stateAfterRelease = await coordinator.state
        guard case let .readyForUpload(finalReport) = stateAfterRelease else {
            return XCTFail("Expected unchanged timeout report")
        }
        XCTAssertEqual(finalReport.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(finalReport.facts.microphoneTestOutcome, .timedOut)
    }

    func testLateFailureAfterTimeoutDoesNotReplaceTimeoutReport()
        async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let lateTerminalAttempted = AudioDiagnosticGateTestSignal()
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: NonCooperativeMicrophoneSignalTester(
                operation: operation
            ),
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01),
                gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                    operationTerminalAttempted: {
                        lateTerminalAttempted.signal()
                    }
                )
            )
        )
        try await coordinator.prepare()
        let diagnosticTask = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await operation.waitUntilStarted()
        _ = try? await diagnosticTask.value

        await operation.releaseFailure()
        await lateTerminalAttempted.wait()

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected unchanged timeout report")
        }
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .timedOut)
    }

    func testTimeoutTriggersMicrophoneCleanup() async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let microphone = NonCooperativeMicrophoneSignalTester(
            operation: operation
        )
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: microphone,
            systemAudioTester: SystemSignalTesterStub(),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01)
            )
        )
        try await coordinator.prepare()
        let diagnosticTask = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await operation.waitUntilStarted()
        _ = try? await diagnosticTask.value

        let cancelCount = await microphone.cancelCount()
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        await operation.releaseSuccess()
    }

    func testTimeoutTriggersSystemAudioCleanup() async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let systemAudio = NonCooperativeSystemSignalTester(
            operation: operation
        )
        let coordinator = AudioDiagnosticCoordinator(
            recordingActivity: RecordingActivityStub(isActive: false),
            permissions: PermissionSnapshotStub(
                snapshot: AudioDiagnosticPermissionSnapshot(
                    microphone: .authorized,
                    screenRecording: .authorized
                )
            ),
            inputDevice: InputDeviceAvailabilityStub(isAvailable: true),
            outputTester: OutputTesterStub(),
            microphoneTester: SignalTesterStub(metrics: audibleMetrics()),
            systemAudioTester: systemAudio,
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer(
                sleeper: ScaledTimeoutSleeper(scale: 0.01)
            )
        )
        try await coordinator.prepare()
        let diagnosticTask = Task {
            try await coordinator.continueAfterOutputConfirmation(
                heardTone: true
            )
        }
        await operation.waitUntilStarted()
        _ = try? await diagnosticTask.value

        let cancelCount = await systemAudio.cancelCount()
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        await operation.releaseSuccess()
    }

    func testTimeoutDoesNotDoubleResume() async throws {
        let operation = NonCooperativeAudioDiagnosticOperation()
        let lateTerminalAttempted = AudioDiagnosticGateTestSignal()
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ImmediateTimeoutSleeper(),
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                operationTerminalAttempted: {
                    lateTerminalAttempted.signal()
                }
            )
        )

        do {
            _ = try await racer.run(
                stage: .systemAudio,
                timeout: 0.1
            ) {
                try await operation.run()
            }
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut(.systemAudio)
            )
        }

        await operation.releaseSuccess()
        await operation.releaseSuccess()
        await lateTerminalAttempted.wait()
    }

    func testCancellationBeforeContinuationRegistrationDoesNotHang()
        async throws {
        let registrationPause = AudioDiagnosticGateSynchronousPause()
        let cancellationRecorded = AudioDiagnosticGateTestSignal()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ImmediateTimeoutSleeper(),
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                beforeContinuationRegistration: {
                    registrationPause.pause()
                },
                cancellationRecorded: {
                    cancellationRecorded.signal()
                }
            )
        )
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    audibleMetrics()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await registrationPause.waitUntilPaused()

        caller.cancel()
        await cancellationRecorded.wait()
        let registrationReleasedAt = Date()
        registrationPause.release()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        XCTAssertLessThan(
            Date().timeIntervalSince(registrationReleasedAt),
            0.5
        )
        guard let result = resultRecorder.result else {
            return XCTFail("caller_completed=false")
        }
        do {
            _ = try result.get()
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationAfterContinuationRegistrationBeforeTaskInstallationCancelsLateTasks()
        async throws {
        let continuationRegistered = AudioDiagnosticGateTestSignal()
        let taskInstallationPause = AudioDiagnosticGateSynchronousPause()
        let cancellationRecorded = AudioDiagnosticGateTestSignal()
        let operation = ControlledAudioDiagnosticGateOperation()
        let sleeper = ControlledAudioDiagnosticGateSleeper()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: sleeper,
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                continuationRegistered: {
                    continuationRegistered.signal()
                },
                beforeTaskInstallation: {
                    taskInstallationPause.pause()
                },
                cancellationRecorded: {
                    cancellationRecorded.signal()
                }
            )
        )
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    try await operation.run()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await continuationRegistered.wait()
        await taskInstallationPause.waitUntilPaused()
        await operation.waitUntilStarted()
        await sleeper.waitUntilStarted()

        caller.cancel()
        await cancellationRecorded.wait()
        taskInstallationPause.release()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        assertCancellationResult(resultRecorder.result)
        let operationWasCancelled =
            await operation.cancellationWasRequested()
        let sleeperWasCancelled =
            await sleeper.cancellationWasRequested()
        XCTAssertTrue(operationWasCancelled)
        XCTAssertTrue(sleeperWasCancelled)
        XCTAssertEqual(resultRecorder.recordCount, 1)

        await operation.releaseSuccess()
        await sleeper.release()
    }

    func testPreCancelledCallerReturnsCancellation() async throws {
        let callerEntered = AudioDiagnosticTestSignal()
        let releaseCaller = AudioDiagnosticTestSignal()
        let registrationPause = AudioDiagnosticGateSynchronousPause()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: ImmediateTimeoutSleeper(),
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                beforeContinuationRegistration: {
                    registrationPause.pause()
                },
                cancellationRecorded: {
                    registrationPause.release()
                }
            )
        )
        let caller = Task {
            await callerEntered.signal()
            await releaseCaller.wait()
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    audibleMetrics()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await callerEntered.wait()

        caller.cancel()
        await releaseCaller.signal()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        assertCancellationResult(resultRecorder.result)
        XCTAssertEqual(resultRecorder.recordCount, 1)
    }

    func testCallerCancellationAfterRegistrationReturnsCancellation()
        async throws {
        let operation = ControlledAudioDiagnosticGateOperation()
        let sleeper = ControlledAudioDiagnosticGateSleeper()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(sleeper: sleeper)
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    try await operation.run()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await operation.waitUntilStarted()
        await sleeper.waitUntilStarted()

        caller.cancel()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        assertCancellationResult(resultRecorder.result)
        let operationWasCancelled =
            await operation.cancellationWasRequested()
        let sleeperWasCancelled =
            await sleeper.cancellationWasRequested()
        XCTAssertTrue(operationWasCancelled)
        XCTAssertTrue(sleeperWasCancelled)
        XCTAssertEqual(resultRecorder.recordCount, 1)

        await operation.releaseSuccess()
        await sleeper.release()
    }

    func testCancellationWinsAgainstLaterTimeout() async throws {
        let cancellationRecorded = AudioDiagnosticGateTestSignal()
        let operation = ControlledAudioDiagnosticGateOperation()
        let sleeper = ControlledAudioDiagnosticGateSleeper()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: sleeper,
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                cancellationRecorded: {
                    cancellationRecorded.signal()
                }
            )
        )
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .systemAudio,
                    timeout: 1
                ) {
                    try await operation.run()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await operation.waitUntilStarted()
        await sleeper.waitUntilStarted()

        caller.cancel()
        await cancellationRecorded.wait()
        await sleeper.release()
        await operation.releaseSuccess()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        assertCancellationResult(resultRecorder.result)
        XCTAssertEqual(resultRecorder.recordCount, 1)
    }

    func testCancellationWinsAgainstLaterOperationSuccess() async throws {
        let cancellationRecorded = AudioDiagnosticGateTestSignal()
        let operation = ControlledAudioDiagnosticGateOperation()
        let sleeper = ControlledAudioDiagnosticGateSleeper()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(
            sleeper: sleeper,
            gateHooks: AudioDiagnosticOperationTimeoutGateHooks(
                cancellationRecorded: {
                    cancellationRecorded.signal()
                }
            )
        )
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    try await operation.run()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await operation.waitUntilStarted()
        await sleeper.waitUntilStarted()

        caller.cancel()
        await cancellationRecorded.wait()
        await operation.releaseSuccess()
        await sleeper.release()

        await fulfillment(of: [callerCompleted], timeout: 0.5)
        assertCancellationResult(resultRecorder.result)
        XCTAssertEqual(resultRecorder.recordCount, 1)
    }

    func testOperationSuccessWinsAgainstLaterCancellation() async throws {
        let operation = ControlledAudioDiagnosticGateOperation()
        let sleeper = ControlledAudioDiagnosticGateSleeper()
        let resultRecorder = AudioDiagnosticGateResultRecorder()
        let callerCompleted = expectation(description: "caller completed")
        let racer = LiveAudioDiagnosticTimeoutRacer(sleeper: sleeper)
        let caller = Task {
            do {
                let metrics = try await racer.run(
                    stage: .microphone,
                    timeout: 1
                ) {
                    try await operation.run()
                }
                resultRecorder.record(.success(metrics))
            } catch {
                resultRecorder.record(.failure(error))
            }
            callerCompleted.fulfill()
        }
        await operation.waitUntilStarted()
        await sleeper.waitUntilStarted()

        await operation.releaseSuccess()
        await fulfillment(of: [callerCompleted], timeout: 0.5)
        caller.cancel()
        await sleeper.release()

        let result = try XCTUnwrap(resultRecorder.result)
        XCTAssertEqual(try result.get(), audibleMetrics())
        XCTAssertEqual(resultRecorder.recordCount, 1)
    }

    private func assertCancellationResult(
        _ result: Result<AudioSignalMetrics, any Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result else {
            return XCTFail("Expected caller result", file: file, line: line)
        }
        do {
            _ = try result.get()
            XCTFail("Expected CancellationError", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Expected CancellationError, got \(error)",
                file: file,
                line: line
            )
        }
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

    func testDependencyFailureCreatesUploadableReportAndCleansResources()
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
        try await coordinator.continueAfterOutputConfirmation(
            heardTone: true
        )

        let state = await coordinator.state
        guard case let .readyForUpload(report) = state else {
            return XCTFail("Expected report after failure, got \(state)")
        }
        XCTAssertEqual(report.primaryIssue, .microphoneDiagnosticFailed)
        XCTAssertEqual(report.facts.microphoneTestOutcome, .failed)
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

    func testDiagnosticConfigurationIncludesTestToneWithoutChangingMeetingTapPolicy() {
        let diagnostic = AudioDiagnosticSystemCaptureConfiguration()
        XCTAssertTrue(diagnostic.capturesAudio)
        XCTAssertFalse(diagnostic.capturesMicrophone)
        XCTAssertFalse(diagnostic.excludesCurrentProcessAudio)
        XCTAssertFalse(diagnostic.excludesCurrentApplication)
        let production = SystemAudioTapPolicy.description(excluding: 77)
        XCTAssertEqual(production.processes, [77])
    }

    func testCoreAudioFactoryDefersHardwareAccessUntilSessionRuns()
        async throws {
        let factory = CoreAudioDiagnosticSessionFactory()

        let session = try await factory.makeSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration()
        )

        XCTAssertTrue(
            session is SystemAudioDiagnosticSession
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

    func testSystemSessionStartsThenCallbacksMeasuresAndStops()
        async throws {
        let events = AudioDiagnosticEventRecorder()
        let runtime = SystemCaptureRuntimeStub(events: events)
        let session = SystemAudioDiagnosticSession(
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

    func testSystemSessionStartFailureStillStopsExactlyOnce() async {
        let runtime = FailingSystemCaptureRuntime()
        let session = SystemAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(),
            runtime: runtime
        )

        do {
            _ = try await session.testSignal(duration: 3) {}
            XCTFail("Expected setup failure")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticLiveSignalError,
                .systemAudioCaptureNotStarted
            )
        }
        await session.cancel()
        let stopCount = await runtime.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testSystemSessionCancelDuringSuspendedStartIsIdempotent()
        async {
        let runtime = SuspendingSystemCaptureRuntime()
        let session = SystemAudioDiagnosticSession(
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

        let metrics = try await racer.run(
            stage: .microphone,
            timeout: 4
        ) {
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
            _ = try await racer.run(
                stage: .microphone,
                timeout: 4
            ) {
                for try await metrics in pair.stream {
                    return metrics
                }
                throw CancellationError()
            }
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(
                error as? AudioDiagnosticCoordinatorError,
                .timedOut(.microphone)
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
    let events: AudioDiagnosticEventRecorder?

    init(
        isActive: Bool,
        events: AudioDiagnosticEventRecorder? = nil
    ) {
        self.isActive = isActive
        self.events = events
    }

    func isRecordingActive() async -> Bool {
        events?.append("recording")
        return isActive
    }
}

private struct PermissionSnapshotStub: AudioDiagnosticPermissionChecking {
    let snapshot: AudioDiagnosticPermissionSnapshot
    let events: AudioDiagnosticEventRecorder?

    init(
        snapshot: AudioDiagnosticPermissionSnapshot,
        events: AudioDiagnosticEventRecorder? = nil
    ) {
        self.snapshot = snapshot
        self.events = events
    }

    func permissionSnapshot() async -> AudioDiagnosticPermissionSnapshot {
        events?.append("permissions")
        return snapshot
    }
}

private actor SuspendingPermissionSnapshotStub:
    AudioDiagnosticPermissionChecking {
    private let snapshot: AudioDiagnosticPermissionSnapshot
    private let events: AudioDiagnosticEventRecorder
    private let requested = AudioDiagnosticGateTestSignal()
    private var continuation:
        CheckedContinuation<AudioDiagnosticPermissionSnapshot, Never>?

    init(
        snapshot: AudioDiagnosticPermissionSnapshot,
        events: AudioDiagnosticEventRecorder
    ) {
        self.snapshot = snapshot
        self.events = events
    }

    func permissionSnapshot() async -> AudioDiagnosticPermissionSnapshot {
        events.append("permissions")
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested.signal()
        }
    }

    func waitUntilRequested() async {
        await requested.wait()
    }

    func release() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private struct InputDeviceAvailabilityStub:
    AudioDiagnosticInputDeviceChecking {
    let isAvailable: Bool
    let events: AudioDiagnosticEventRecorder?

    init(
        isAvailable: Bool,
        events: AudioDiagnosticEventRecorder? = nil
    ) {
        self.isAvailable = isAvailable
        self.events = events
    }

    func inputDeviceIsAvailable() async -> Bool {
        events?.append("inputDevice")
        return isAvailable
    }
}

private struct OutputTesterStub: AudioOutputTesting {
    let events: AudioDiagnosticEventRecorder?

    init(events: AudioDiagnosticEventRecorder? = nil) {
        self.events = events
    }

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        events?.append("tone")
        return AudioOutputTestResult(
            wasScheduled: true,
            duration: duration,
            outputDeviceID: nil
        )
    }

    func stop() async {
        events?.append("outputStop")
    }
}

private actor SuspendingOutputTester: AudioOutputTesting {
    private let events: AudioDiagnosticEventRecorder
    private let playStarted = AudioDiagnosticGateTestSignal()
    private var continuation:
        CheckedContinuation<AudioOutputTestResult, Error>?

    init(events: AudioDiagnosticEventRecorder) {
        self.events = events
    }

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        events.append("tone")
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            playStarted.signal()
        }
    }

    func stop() async {
        events.append("outputStop")
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilPlayStarted() async {
        await playStarted.wait()
    }

    func releaseToneForTestTeardown() {
        continuation?.resume(
            returning: AudioOutputTestResult(
                wasScheduled: true,
                duration: 1,
                outputDeviceID: nil
            )
        )
        continuation = nil
    }
}

private actor FailingPreparationOutputTester: AudioOutputTesting {
    private let events: AudioDiagnosticEventRecorder

    init(events: AudioDiagnosticEventRecorder) {
        self.events = events
    }

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        _ = duration
        events.append("tone")
        throw AudioDiagnosticTestFailure.failed
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
    let events: AudioDiagnosticEventRecorder?

    init(events: AudioDiagnosticEventRecorder? = nil) {
        self.events = events
    }

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        throw AudioDiagnosticTestFailure.failed
    }

    func cancel() async {
        events?.append("microphoneCancel")
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

private actor SlowStartupSignalTester: AudioDiagnosticSignalTesting {
    private let simulatedStartup: TimeInterval
    private let scale: TimeInterval

    init(simulatedStartup: TimeInterval, scale: TimeInterval) {
        self.simulatedStartup = simulatedStartup
        self.scale = scale
    }

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        let simulatedDuration = simulatedStartup + duration
        try await Task.sleep(
            nanoseconds: UInt64(
                (simulatedDuration * scale * 1_000_000_000).rounded()
            )
        )
        return audibleMetrics()
    }

    func cancel() async {}
}

private actor SlowSystemAudioStartupTester:
    AudioDiagnosticSystemSignalTesting {
    private let simulatedSetup: TimeInterval
    private let scale: TimeInterval

    init(simulatedSetup: TimeInterval, scale: TimeInterval) {
        self.simulatedSetup = simulatedSetup
        self.scale = scale
    }

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        try await afterCaptureStarts()
        let simulatedDuration = simulatedSetup + duration
        try await Task.sleep(
            nanoseconds: UInt64(
                (simulatedDuration * scale * 1_000_000_000).rounded()
            )
        )
        return audibleMetrics()
    }

    func cancel() async {}
}

private struct FailingSystemSignalTester:
    AudioDiagnosticSystemSignalTesting {
    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        _ = duration
        _ = afterCaptureStarts
        throw AudioDiagnosticTestFailure.failed
    }

    func cancel() async {}
}

private struct ScaledTimeoutSleeper: AudioDiagnosticTimeoutSleeping {
    let scale: TimeInterval

    func sleep(for duration: TimeInterval) async throws {
        let boundedDuration = duration.isFinite
            ? min(max(0, duration), 3_600)
            : 0
        let scaledDuration = boundedDuration * scale
        try await Task.sleep(
            nanoseconds: UInt64(
                (scaledDuration * 1_000_000_000).rounded()
            )
        )
    }
}

private actor NonCooperativeAudioDiagnosticOperation {
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation:
        CheckedContinuation<AudioSignalMetrics, Error>?
    private var hasStarted = false

    func run() async throws -> AudioSignalMetrics {
        if !hasStarted {
            hasStarted = true
            let waiters = startedContinuations
            startedContinuations.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseSuccess() {
        resultContinuation?.resume(returning: audibleMetrics())
        resultContinuation = nil
    }

    func releaseFailure() {
        resultContinuation?.resume(
            throwing: AudioDiagnosticTestFailure.failed
        )
        resultContinuation = nil
    }
}

private final class AudioDiagnosticGateTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let currentWaiters = lock.withLock { () -> [CheckedContinuation<
            Void,
            Never
        >] in
            guard !hasSignaled else { return [] }
            hasSignaled = true
            let currentWaiters = waiters
            waiters.removeAll()
            return currentWaiters
        }
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !hasSignaled else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    var isSignaled: Bool {
        lock.withLock { hasSignaled }
    }
}

private final class AudioDiagnosticGateSynchronousPause: @unchecked Sendable {
    private let entered = AudioDiagnosticGateTestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilPaused() async {
        await entered.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class AudioDiagnosticGateResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<AudioSignalMetrics, any Error>?
    private var storedRecordCount = 0

    var result: Result<AudioSignalMetrics, any Error>? {
        lock.withLock { storedResult }
    }

    var recordCount: Int {
        lock.withLock { storedRecordCount }
    }

    func record(_ result: Result<AudioSignalMetrics, any Error>) {
        lock.withLock {
            storedResult = result
            storedRecordCount += 1
        }
    }
}

private actor ControlledAudioDiagnosticGateOperation {
    private let started = AudioDiagnosticGateTestSignal()
    private let cancellationRequested = AudioDiagnosticGateTestSignal()
    private var continuation:
        CheckedContinuation<AudioSignalMetrics, any Error>?

    func run() async throws -> AudioSignalMetrics {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.signal()
            }
        } onCancel: {
            self.cancellationRequested.signal()
        }
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func cancellationWasRequested() -> Bool {
        cancellationRequested.isSignaled
    }

    func releaseSuccess() {
        continuation?.resume(returning: audibleMetrics())
        continuation = nil
    }
}

private actor ControlledAudioDiagnosticGateSleeper:
    AudioDiagnosticTimeoutSleeping {
    private let started = AudioDiagnosticGateTestSignal()
    private let cancellationRequested = AudioDiagnosticGateTestSignal()
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(for duration: TimeInterval) async throws {
        _ = duration
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.signal()
            }
        } onCancel: {
            self.cancellationRequested.signal()
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func cancellationWasRequested() -> Bool {
        cancellationRequested.isSignaled
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NonCooperativeMicrophoneSignalTester:
    AudioDiagnosticSignalTesting {
    private let operation: NonCooperativeAudioDiagnosticOperation
    private var cleanupCount = 0

    init(operation: NonCooperativeAudioDiagnosticOperation) {
        self.operation = operation
    }

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        _ = duration
        return try await operation.run()
    }

    func cancel() async {
        cleanupCount += 1
    }

    func cancelCount() -> Int {
        cleanupCount
    }
}

private actor NonCooperativeSystemSignalTester:
    AudioDiagnosticSystemSignalTesting {
    private let operation: NonCooperativeAudioDiagnosticOperation
    private var cleanupCount = 0

    init(operation: NonCooperativeAudioDiagnosticOperation) {
        self.operation = operation
    }

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        _ = duration
        try await afterCaptureStarts()
        return try await operation.run()
    }

    func cancel() async {
        cleanupCount += 1
    }

    func cancelCount() -> Int {
        cleanupCount
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
        stage: AudioDiagnosticStage,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics {
        _ = stage
        _ = timeout
        return try await operation()
    }
}

private struct ThrowingTimeoutRacer: AudioDiagnosticTimeoutRacing {
    func run(
        stage: AudioDiagnosticStage,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics {
        _ = timeout
        _ = operation
        throw AudioDiagnosticCoordinatorError.timedOut(stage)
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

private actor SystemCaptureRuntimeStub:
    AudioDiagnosticSystemCaptureRuntime {
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

private actor FailingSystemCaptureRuntime:
    AudioDiagnosticSystemCaptureRuntime {
    private(set) var stopCount = 0

    func start(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws {
        _ = configuration
        throw AudioDiagnosticLiveSignalError.systemAudioCaptureNotStarted
    }

    func measureSignal(duration: TimeInterval) async throws
        -> AudioSignalMetrics {
        fatalError("Must not measure after failed start")
    }

    func stop() async {
        stopCount += 1
    }
}

private actor SuspendingSystemCaptureRuntime:
    AudioDiagnosticSystemCaptureRuntime {
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
