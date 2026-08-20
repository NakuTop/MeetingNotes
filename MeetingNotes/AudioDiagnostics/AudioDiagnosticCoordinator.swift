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
    case timedOut(AudioDiagnosticStage)
}

actor AudioDiagnosticCoordinator {
    private static let outputToneDuration: TimeInterval = 1
    private static let signalObservationDuration: TimeInterval = 3
    private static let microphoneOperationTimeout: TimeInterval = 12
    private static let systemAudioOperationTimeout: TimeInterval = 15

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
    private var preparationGeneration: UInt64 = 0
    private var preparationToneRequiresCleanup = false

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
        preparationGeneration &+= 1
        let requestedGeneration = preparationGeneration
        try ensurePreparationIsCurrent(requestedGeneration)

        state = .checkingPermissions
        let recordingIsActive = await recordingActivity.isRecordingActive()
        try ensurePreparationIsCurrent(requestedGeneration)
        guard !recordingIsActive else {
            state = .failed("recordingActive")
            throw AudioDiagnosticCoordinatorError.recordingActive
        }

        let currentPermissionSnapshot = await permissions.permissionSnapshot()
        try ensurePreparationIsCurrent(requestedGeneration)
        permissionSnapshot = currentPermissionSnapshot

        let currentInputDeviceAvailable =
            await inputDevice.inputDeviceIsAvailable()
        try ensurePreparationIsCurrent(requestedGeneration)
        inputDeviceAvailable = currentInputDeviceAvailable

        state = .playingOutputTone
        preparationToneRequiresCleanup = true
        let result: AudioOutputTestResult
        do {
            result = try await outputTester.playTestTone(
                duration: Self.outputToneDuration
            )
            try ensurePreparationIsCurrent(requestedGeneration)
        } catch {
            let generationIsCurrent =
                preparationGeneration == requestedGeneration
            let wasCancelled =
                !generationIsCurrent
                || Task.isCancelled
                || error is CancellationError
            if generationIsCurrent {
                if wasCancelled {
                    preparationGeneration &+= 1
                    state = .failed("cancelled")
                } else {
                    state = .failed("outputToneFailed")
                }
            }
            await stopPreparationToneIfNeeded()
            if wasCancelled {
                throw CancellationError()
            }
            throw error
        }
        preparationToneRequiresCleanup = false
        outputToneWasScheduled = result.wasScheduled
        state = .awaitingOutputConfirmation
    }

    private func ensurePreparationIsCurrent(
        _ requestedGeneration: UInt64
    ) throws {
        guard preparationGeneration == requestedGeneration else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
        } catch {
            preparationGeneration &+= 1
            state = .failed("cancelled")
            throw error
        }
    }

    func continueAfterOutputConfirmation(heardTone: Bool) async throws {
        guard state == .awaitingOutputConfirmation,
              let permissionSnapshot else {
            throw AudioDiagnosticCoordinatorError.invalidState(state)
        }
        resourcesRequireCleanup = true

        let microphoneShouldRun =
            permissionSnapshot.microphone.isAuthorized
            && inputDeviceAvailable
        let systemAudioShouldRun =
            permissionSnapshot.screenRecording.isAuthorized

        var microphoneOutcome: AudioDiagnosticStageOutcome =
            microphoneShouldRun ? .notRun : .skipped
        var systemAudioOutcome: AudioDiagnosticStageOutcome =
            systemAudioShouldRun ? .notRun : .skipped
        var microphoneMetrics: AudioSignalMetrics?
        var systemAudioMetrics: AudioSignalMetrics?

        do {
            if microphoneShouldRun {
                state = .testingMicrophone
                do {
                    microphoneMetrics = try await timeoutRacer.run(
                        stage: .microphone,
                        timeout: Self.microphoneOperationTimeout
                    ) { [microphoneTester] in
                        try await microphoneTester.testSignal(
                            duration: Self.signalObservationDuration
                        )
                    }
                    microphoneOutcome = .succeeded
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as AudioDiagnosticCoordinatorError {
                    guard error == .timedOut(.microphone) else {
                        throw error
                    }
                    microphoneOutcome = .timedOut
                } catch {
                    microphoneOutcome = .failed
                }
                guard microphoneOutcome == .succeeded else {
                    await cleanupResourcesIfNeeded()
                    state = .readyForUpload(
                        stageFailureReport(
                            permissionSnapshot: permissionSnapshot,
                            primaryIssue: microphoneOutcome == .timedOut
                                ? .microphoneDiagnosticTimedOut
                                : .microphoneDiagnosticFailed,
                            heardTone: heardTone,
                            microphoneMetrics: microphoneMetrics,
                            systemAudioMetrics: nil,
                            microphoneOutcome: microphoneOutcome,
                            systemAudioOutcome: .notRun
                        )
                    )
                    return
                }
            }

            if systemAudioShouldRun {
                state = .testingSystemAudio
                do {
                    systemAudioMetrics = try await timeoutRacer.run(
                        stage: .systemAudio,
                        timeout: Self.systemAudioOperationTimeout
                    ) { [systemAudioTester, outputTester] in
                        try await systemAudioTester.testSignal(
                            duration: Self.signalObservationDuration
                        ) {
                            _ = try await outputTester.playTestTone(
                                duration: Self.outputToneDuration
                            )
                        }
                    }
                    systemAudioOutcome = .succeeded
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as AudioDiagnosticCoordinatorError {
                    guard error == .timedOut(.systemAudio) else {
                        throw error
                    }
                    systemAudioOutcome = .timedOut
                } catch {
                    systemAudioOutcome = .failed
                }
                guard systemAudioOutcome == .succeeded else {
                    await cleanupResourcesIfNeeded()
                    state = .readyForUpload(
                        stageFailureReport(
                            permissionSnapshot: permissionSnapshot,
                            primaryIssue: systemAudioOutcome == .timedOut
                                ? .systemAudioDiagnosticTimedOut
                                : .systemAudioDiagnosticFailed,
                            heardTone: heardTone,
                            microphoneMetrics: microphoneMetrics,
                            systemAudioMetrics: nil,
                            microphoneOutcome: microphoneOutcome,
                            systemAudioOutcome: systemAudioOutcome
                        )
                    )
                    return
                }
            }

            let facts = AudioDiagnosticFacts(
                microphonePermission: permissionSnapshot.microphone,
                screenPermission: permissionSnapshot.screenRecording,
                inputDeviceAvailable: inputDeviceAvailable,
                outputToneWasScheduled: outputToneWasScheduled,
                userHeardOutputTone: heardTone,
                microphoneMetrics: microphoneMetrics,
                systemAudioMetrics: systemAudioMetrics,
                historicalPlaybackFailed: false,
                microphoneTestOutcome: microphoneOutcome,
                systemAudioTestOutcome: systemAudioOutcome
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
            } else if case .failed = state {
                // Preserve a more specific failure selected above.
            } else {
                state = .failed(String(describing: error))
            }
            throw error
        }
    }

    private func stageFailureReport(
        permissionSnapshot: AudioDiagnosticPermissionSnapshot,
        primaryIssue: AudioDiagnosticIssueCode,
        heardTone: Bool,
        microphoneMetrics: AudioSignalMetrics?,
        systemAudioMetrics: AudioSignalMetrics?,
        microphoneOutcome: AudioDiagnosticStageOutcome,
        systemAudioOutcome: AudioDiagnosticStageOutcome
    ) -> AudioDiagnosticReport {
        AudioDiagnosticReport(
            primaryIssue: primaryIssue,
            supportingIssues: [],
            facts: AudioDiagnosticFacts(
                microphonePermission: permissionSnapshot.microphone,
                screenPermission: permissionSnapshot.screenRecording,
                inputDeviceAvailable: inputDeviceAvailable,
                outputToneWasScheduled: outputToneWasScheduled,
                userHeardOutputTone: heardTone,
                microphoneMetrics: microphoneMetrics,
                systemAudioMetrics: systemAudioMetrics,
                historicalPlaybackFailed: false,
                microphoneTestOutcome: microphoneOutcome,
                systemAudioTestOutcome: systemAudioOutcome
            )
        )
    }

    func cancel() async {
        preparationGeneration &+= 1
        state = .failed("cancelled")
        await stopPreparationToneIfNeeded()
        await cleanupResourcesIfNeeded()
    }

    private func stopPreparationToneIfNeeded() async {
        guard preparationToneRequiresCleanup else { return }
        preparationToneRequiresCleanup = false
        await outputTester.stop()
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
