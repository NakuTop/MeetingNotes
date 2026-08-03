import Foundation

enum AudioDiagnosticCoordinatorState: Sendable, Equatable {
    case idle
    case checkingPermissions
    case playingOutputTone
    case awaitingOutputConfirmation
    case testingMicrophone
    case testingSystemAudio
    case readyForUpload(AudioDiagnosticReport)
    case failed(String)
}

enum AudioDiagnosticCoordinatorError: Error, Sendable, Equatable {
    case recordingActive
    case invalidState(AudioDiagnosticCoordinatorState)
    case insufficientEvidence
    case timedOut
}

actor AudioDiagnosticCoordinator {
    private static let outputToneDuration: TimeInterval = 1
    private static let signalTestDuration: TimeInterval = 3
    private static let signalTestTimeout: TimeInterval = 4

    private(set) var state: AudioDiagnosticCoordinatorState = .idle

    private let recordingActivity:
        any AudioDiagnosticRecordingActivityChecking
    private let permissions: any AudioDiagnosticPermissionChecking
    private let inputDevice: any AudioDiagnosticInputDeviceChecking
    private let outputTester: any AudioOutputTesting
    private let microphoneTester: any AudioDiagnosticSignalTesting
    private let systemAudioTester: any AudioDiagnosticSystemSignalTesting
    private let ruleEngine: any AudioDiagnosticRuleEvaluating
    private let timeoutRacer: any AudioDiagnosticTimeoutRacing

    private var permissionSnapshot: AudioDiagnosticPermissionSnapshot?
    private var inputDeviceAvailable = false
    private var outputToneWasScheduled = false
    private var resourcesRequireCleanup = false

    init(
        recordingActivity:
            any AudioDiagnosticRecordingActivityChecking,
        permissions: any AudioDiagnosticPermissionChecking,
        inputDevice: any AudioDiagnosticInputDeviceChecking,
        outputTester: any AudioOutputTesting,
        microphoneTester: any AudioDiagnosticSignalTesting,
        systemAudioTester: any AudioDiagnosticSystemSignalTesting,
        ruleEngine: any AudioDiagnosticRuleEvaluating =
            AudioDiagnosticRuleEngine(),
        timeoutRacer: any AudioDiagnosticTimeoutRacing
    ) {
        self.recordingActivity = recordingActivity
        self.permissions = permissions
        self.inputDevice = inputDevice
        self.outputTester = outputTester
        self.microphoneTester = microphoneTester
        self.systemAudioTester = systemAudioTester
        self.ruleEngine = ruleEngine
        self.timeoutRacer = timeoutRacer
    }

    func prepare() async throws {
        guard state == .idle else {
            throw AudioDiagnosticCoordinatorError.invalidState(state)
        }

        state = .checkingPermissions
        guard !(await recordingActivity.isRecordingActive()) else {
            state = .failed("recordingActive")
            throw AudioDiagnosticCoordinatorError.recordingActive
        }

        permissionSnapshot = await permissions.permissionSnapshot()
        inputDeviceAvailable = await inputDevice.inputDeviceIsAvailable()

        state = .playingOutputTone
        let result = try await outputTester.playTestTone(
            duration: Self.outputToneDuration
        )
        outputToneWasScheduled = result.wasScheduled
        state = .awaitingOutputConfirmation
    }

    func continueAfterOutputConfirmation(heardTone: Bool) async throws {
        guard state == .awaitingOutputConfirmation,
              let permissionSnapshot else {
            throw AudioDiagnosticCoordinatorError.invalidState(state)
        }
        resourcesRequireCleanup = true

        do {
            let microphoneMetrics: AudioSignalMetrics?
            if permissionSnapshot.microphone.isAuthorized,
               inputDeviceAvailable {
                state = .testingMicrophone
                microphoneMetrics = try await timeoutRacer.run(
                    timeout: Self.signalTestTimeout
                ) { [microphoneTester] in
                    try await microphoneTester.testSignal(
                        duration: Self.signalTestDuration
                    )
                }
            } else {
                microphoneMetrics = nil
            }

            let systemAudioMetrics: AudioSignalMetrics?
            if permissionSnapshot.screenRecording.isAuthorized {
                state = .testingSystemAudio
                systemAudioMetrics = try await timeoutRacer.run(
                    timeout: Self.signalTestTimeout
                ) { [systemAudioTester, outputTester] in
                    try await systemAudioTester.testSignal(
                        duration: Self.signalTestDuration
                    ) {
                        _ = try await outputTester.playTestTone(
                            duration: Self.outputToneDuration
                        )
                    }
                }
            } else {
                systemAudioMetrics = nil
            }

            let facts = AudioDiagnosticFacts(
                microphonePermission: permissionSnapshot.microphone,
                screenPermission: permissionSnapshot.screenRecording,
                inputDeviceAvailable: inputDeviceAvailable,
                outputToneWasScheduled: outputToneWasScheduled,
                userHeardOutputTone: heardTone,
                microphoneMetrics: microphoneMetrics,
                systemAudioMetrics: systemAudioMetrics,
                historicalPlaybackFailed: false
            )
            guard let report = ruleEngine.evaluate(facts) else {
                state = .failed("insufficientEvidence")
                throw AudioDiagnosticCoordinatorError.insufficientEvidence
            }
            await cleanupResourcesIfNeeded()
            state = .readyForUpload(report)
        } catch {
            await cleanupResourcesIfNeeded()
            if error is CancellationError {
                state = .failed("cancelled")
            } else if error as? AudioDiagnosticCoordinatorError == .timedOut {
                state = .failed("timedOut")
            } else if case .failed = state {
                // Preserve a more specific failure selected above.
            } else {
                state = .failed(String(describing: error))
            }
            throw error
        }
    }

    func cancel() async {
        guard resourcesRequireCleanup else { return }
        state = .failed("cancelled")
        await cleanupResourcesIfNeeded()
    }

    private func cleanupResourcesIfNeeded() async {
        guard resourcesRequireCleanup else { return }
        resourcesRequireCleanup = false
        await outputTester.stop()
        await microphoneTester.cancel()
        await systemAudioTester.cancel()
    }
}

extension AudioDiagnosticCoordinator: AudioDiagnosticCoordinating {
    func currentState() async -> AudioDiagnosticCoordinatorState {
        state
    }
}
