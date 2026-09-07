import AVFoundation
import Foundation

struct AudioDiagnosticPermissionSnapshot: Sendable, Equatable {
    let microphone: AudioDiagnosticPermissionStatus
    // Legacy screen-based reports may still carry this fact. Pure audio has
    // no public permission preflight; nil means not applicable, not denied.
    let screenRecording: AudioDiagnosticPermissionStatus?
}

protocol AudioDiagnosticCoordinating: Sendable {
    func prepare() async throws
    func continueAfterOutputConfirmation(heardTone: Bool) async throws
    func cancel() async
    func currentState() async -> AudioDiagnosticCoordinatorState
}

protocol AudioDiagnosticCoordinatorCreating: Sendable {
    func makeCoordinator() async -> any AudioDiagnosticCoordinating
}

protocol AudioDiagnosticRecordingActivityChecking: Sendable {
    func isRecordingActive() async -> Bool
}

protocol AudioDiagnosticPermissionChecking: Sendable {
    func permissionSnapshot() async -> AudioDiagnosticPermissionSnapshot
}

protocol AudioDiagnosticInputDeviceChecking: Sendable {
    func inputDeviceIsAvailable() async -> Bool
}

struct LiveAudioDiagnosticPermissionChecker:
    AudioDiagnosticPermissionChecking {
    let system: any CapturePermissionSystem

    func permissionSnapshot() async -> AudioDiagnosticPermissionSnapshot {
        let microphone = await system.status(for: .microphone)
        return AudioDiagnosticPermissionSnapshot(
            microphone: Self.status(microphone),
            screenRecording: nil
        )
    }

    private static func status(
        _ status: CapturePermissionStatus
    ) -> AudioDiagnosticPermissionStatus {
        switch status {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        case .unavailable:
            .unavailable
        }
    }
}

struct LiveAudioDiagnosticInputDeviceChecker:
    AudioDiagnosticInputDeviceChecking {
    let catalog: any AudioDeviceDiscovering
    let preference: any AudioInputDevicePreferenceReading

    func inputDeviceIsAvailable() async -> Bool {
        do {
            let snapshot = try await catalog.snapshot()
            let preferred = await preference.preferredAudioInput()
            if AudioInputDeviceResolver.resolveCapture(
                preferred: preferred,
                inputs: snapshot.inputs
            ) != nil {
                return true
            }
            return false
        } catch {
            return false
        }
    }
}

struct MeetingCoordinatorAudioDiagnosticRecordingChecker:
    AudioDiagnosticRecordingActivityChecking {
    let coordinator: MeetingCoordinator

    func isRecordingActive() async -> Bool {
        await coordinator.snapshot().state.blocksCaptureSettingsChanges
    }
}

struct LiveAudioDiagnosticCoordinatorFactory:
    AudioDiagnosticCoordinatorCreating {
    let recordingActivity: any AudioDiagnosticRecordingActivityChecking
    let permissions: any AudioDiagnosticPermissionChecking
    let inputDevice: any AudioDiagnosticInputDeviceChecking
    let outputTester: any AudioOutputTesting
    let inputPreference: any AudioInputDevicePreferenceReading

    func makeCoordinator() async -> any AudioDiagnosticCoordinating {
        AudioDiagnosticCoordinator(
            recordingActivity: recordingActivity,
            permissions: permissions,
            inputDevice: inputDevice,
            outputTester: outputTester,
            microphoneTester: LiveMicrophoneAudioDiagnosticSignalTester(
                provider: AdaptiveMicrophoneSampleProvider(),
                inputPreference: inputPreference
            ),
            systemAudioTester: LiveSystemAudioDiagnosticSignalTester(),
            timeoutRacer: LiveAudioDiagnosticTimeoutRacer()
        )
    }
}

protocol AudioDiagnosticSignalTesting: Sendable {
    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics
    func testSignal(
        duration: TimeInterval,
        onMetrics: @escaping @Sendable (AudioSignalMetrics) async -> Void
    ) async throws -> AudioSignalMetrics
    func cancel() async
}

extension AudioDiagnosticSignalTesting {
    func testSignal(
        duration: TimeInterval,
        onMetrics: @escaping @Sendable (AudioSignalMetrics) async -> Void
    ) async throws -> AudioSignalMetrics {
        let metrics = try await testSignal(duration: duration)
        await onMetrics(metrics)
        return metrics
    }
}

protocol AudioDiagnosticSystemSignalTesting: Sendable {
    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics
    func cancel() async
}

protocol AudioDiagnosticRuleEvaluating: Sendable {
    func evaluate(_ facts: AudioDiagnosticFacts) -> AudioDiagnosticReport?
}

extension AudioDiagnosticRuleEngine: AudioDiagnosticRuleEvaluating {}

protocol AudioDiagnosticTimeoutRacing: Sendable {
    func run(
        stage: AudioDiagnosticStage,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics
}

protocol AudioDiagnosticTimeoutSleeping: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct ContinuousAudioDiagnosticTimeoutSleeper:
    AudioDiagnosticTimeoutSleeping {
    func sleep(for duration: TimeInterval) async throws {
        let boundedDuration = duration.isFinite
            ? min(max(0, duration), 3_600)
            : 0
        let nanoseconds = UInt64(
            (boundedDuration * 1_000_000_000).rounded()
        )
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct LiveAudioDiagnosticTimeoutRacer: AudioDiagnosticTimeoutRacing {
    private let sleeper: any AudioDiagnosticTimeoutSleeping
    private let gateHooks: AudioDiagnosticOperationTimeoutGateHooks

    init(
        sleeper: any AudioDiagnosticTimeoutSleeping =
            ContinuousAudioDiagnosticTimeoutSleeper(),
        gateHooks: AudioDiagnosticOperationTimeoutGateHooks = .none
    ) {
        self.sleeper = sleeper
        self.gateHooks = gateHooks
    }

    func run(
        stage: AudioDiagnosticStage,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics
    ) async throws -> AudioSignalMetrics {
        let gate = AudioDiagnosticOperationTimeoutGate(
            stage: stage,
            timeout: timeout,
            operation: operation,
            sleeper: sleeper,
            hooks: gateHooks
        )
        return try await gate.run()
    }
}

struct AudioDiagnosticOperationTimeoutGateHooks: Sendable {
    let beforeContinuationRegistration: @Sendable () -> Void
    let continuationRegistered: @Sendable () -> Void
    let beforeTaskInstallation: @Sendable () -> Void
    let cancellationRecorded: @Sendable () -> Void
    let operationTerminalAttempted: @Sendable () -> Void

    init(
        beforeContinuationRegistration: @escaping @Sendable () -> Void = {},
        continuationRegistered: @escaping @Sendable () -> Void = {},
        beforeTaskInstallation: @escaping @Sendable () -> Void = {},
        cancellationRecorded: @escaping @Sendable () -> Void = {},
        operationTerminalAttempted: @escaping @Sendable () -> Void = {}
    ) {
        self.beforeContinuationRegistration = beforeContinuationRegistration
        self.continuationRegistered = continuationRegistered
        self.beforeTaskInstallation = beforeTaskInstallation
        self.cancellationRecorded = cancellationRecorded
        self.operationTerminalAttempted = operationTerminalAttempted
    }

    static let none = AudioDiagnosticOperationTimeoutGateHooks()
}

private final class AudioDiagnosticOperationTimeoutGate:
    @unchecked Sendable {
    private struct OperationFailure: @unchecked Sendable {
        let error: any Error
    }

    private enum TerminalResult: @unchecked Sendable {
        case success(AudioSignalMetrics)
        case failure(OperationFailure)
        case timedOut
        case cancelled
    }

    private struct TerminalAction {
        let continuation: CheckedContinuation<AudioSignalMetrics, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let stage: AudioDiagnosticStage
    private let timeout: TimeInterval
    private let operation: @Sendable () async throws -> AudioSignalMetrics
    private let sleeper: any AudioDiagnosticTimeoutSleeping
    private let hooks: AudioDiagnosticOperationTimeoutGateHooks

    private var continuation: CheckedContinuation<AudioSignalMetrics, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: TerminalResult?

    init(
        stage: AudioDiagnosticStage,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> AudioSignalMetrics,
        sleeper: any AudioDiagnosticTimeoutSleeping,
        hooks: AudioDiagnosticOperationTimeoutGateHooks
    ) {
        self.stage = stage
        self.timeout = timeout
        self.operation = operation
        self.sleeper = sleeper
        self.hooks = hooks
    }

    func run() async throws -> AudioSignalMetrics {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            hooks.beforeContinuationRegistration()
            return try await withCheckedThrowingContinuation { continuation in
                if let terminalResult = registerContinuation(continuation) {
                    resume(continuation, with: terminalResult)
                    return
                }
                hooks.continuationRegistered()
                let operation = self.operation
                let operationTerminalAttempted =
                    hooks.operationTerminalAttempted
                let operationTask = Task { [weak self] in
                    do {
                        let metrics = try await operation()
                        self?.operationSucceeded(metrics)
                    } catch {
                        self?.operationFailed(
                            OperationFailure(error: error)
                        )
                    }
                    operationTerminalAttempted()
                }
                let sleeper = self.sleeper
                let timeout = self.timeout
                let timeoutTask = Task { [weak self] in
                    try? await sleeper.sleep(for: timeout)
                    self?.timeoutFired()
                }
                hooks.beforeTaskInstallation()
                installTasks(
                    operationTask: operationTask,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            self.cancelPending()
        }
    }

    private func registerContinuation(
        _ continuation: CheckedContinuation<AudioSignalMetrics, Error>
    ) -> TerminalResult? {
        lock.withLock {
            if let terminalResult {
                return terminalResult
            }
            self.continuation = continuation
            return nil
        }
    }

    private func installTasks(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard terminalResult == nil else { return true }
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    private func operationSucceeded(_ metrics: AudioSignalMetrics) {
        finish(
            with: .success(metrics),
            cancelOperation: false,
            cancelTimeout: true
        )
    }

    private func operationFailed(_ failure: OperationFailure) {
        finish(
            with: .failure(failure),
            cancelOperation: false,
            cancelTimeout: true
        )
    }

    private func timeoutFired() {
        finish(
            with: .timedOut,
            cancelOperation: true,
            cancelTimeout: false
        )
    }

    private func cancelPending() {
        let cancellationWon = finish(
            with: .cancelled,
            cancelOperation: true,
            cancelTimeout: true
        )
        if cancellationWon {
            hooks.cancellationRecorded()
        }
    }

    @discardableResult
    private func finish(
        with result: TerminalResult,
        cancelOperation: Bool,
        cancelTimeout: Bool
    ) -> Bool {
        let action = lock.withLock { () -> TerminalAction? in
            guard terminalResult == nil else { return nil }
            terminalResult = result
            let action = TerminalAction(
                continuation: continuation,
                operationTask: operationTask,
                timeoutTask: timeoutTask
            )
            continuation = nil
            operationTask = nil
            timeoutTask = nil
            return action
        }
        guard let action else { return false }

        if cancelOperation {
            action.operationTask?.cancel()
        }
        if cancelTimeout {
            action.timeoutTask?.cancel()
        }
        if let continuation = action.continuation {
            resume(continuation, with: result)
        }
        return true
    }

    private func resume(
        _ continuation: CheckedContinuation<AudioSignalMetrics, Error>,
        with result: TerminalResult
    ) {
        switch result {
        case let .success(metrics):
            continuation.resume(returning: metrics)
        case let .failure(failure):
            continuation.resume(throwing: failure.error)
        case .timedOut:
            continuation.resume(
                throwing: AudioDiagnosticCoordinatorError.timedOut(stage)
            )
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }
}

struct LiveAudioDiagnosticObservationWindow: Sendable {
    private let sleeper: any AudioDiagnosticTimeoutSleeping

    init(
        sleeper: any AudioDiagnosticTimeoutSleeping =
            ContinuousAudioDiagnosticTimeoutSleeper()
    ) {
        self.sleeper = sleeper
    }

    func observe<Element: Sendable>(
        _ stream: AsyncThrowingStream<Element, Error>,
        duration: TimeInterval,
        onElement: @escaping @Sendable (Element) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await element in stream {
                    try Task.checkCancellation()
                    try await onElement(element)
                }
            }
            group.addTask { [sleeper] in
                try await sleeper.sleep(for: duration)
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

private actor AudioDiagnosticSignalAccumulatorStore {
    private var accumulator = AudioSignalAccumulator()

    func ingest(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int
    ) {
        accumulator.ingest(
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    func snapshot() -> AudioSignalMetrics {
        accumulator.snapshot()
    }
}

enum AudioDiagnosticLiveSignalError: Error, Sendable, Equatable {
    case alreadyRunning
    case unsupportedPCMFormat
    case systemAudioCaptureNotStarted
    case systemAudioBufferOverflow
}

actor LiveMicrophoneAudioDiagnosticSignalTester:
    AudioDiagnosticSignalTesting {
    private let provider: any MicrophoneSampleProviding
    private let inputPreference: any AudioInputDevicePreferenceReading
    private let observationWindow: LiveAudioDiagnosticObservationWindow
    private var activeGeneration: UInt64?
    private var providerGeneration: UInt64?
    private var generation: UInt64 = 0

    init(
        provider: any MicrophoneSampleProviding,
        inputPreference: any AudioInputDevicePreferenceReading,
        observationSleeper: any AudioDiagnosticTimeoutSleeping =
            ContinuousAudioDiagnosticTimeoutSleeper()
    ) {
        self.provider = provider
        self.inputPreference = inputPreference
        observationWindow = LiveAudioDiagnosticObservationWindow(
            sleeper: observationSleeper
        )
    }

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        try await testSignal(duration: duration) { _ in }
    }

    func testSignal(
        duration: TimeInterval,
        onMetrics: @escaping @Sendable (AudioSignalMetrics) async -> Void
    ) async throws -> AudioSignalMetrics {
        guard activeGeneration == nil else {
            throw AudioDiagnosticLiveSignalError.alreadyRunning
        }
        generation &+= 1
        let requestedGeneration = generation
        activeGeneration = requestedGeneration

        do {
            let metrics = try await withTaskCancellationHandler {
                let deviceID = await inputPreference.preferredInputDeviceID()
                try ensureCurrent(requestedGeneration)
                providerGeneration = requestedGeneration
                let stream = try await provider.start(deviceID: deviceID)
                try ensureCurrent(requestedGeneration)
                let accumulator = AudioDiagnosticSignalAccumulatorStore()
                try await observationWindow.observe(
                    stream,
                    duration: duration
                ) { sample in
                    let samples = try Self.ownedSamples(from: sample.buffer)
                    await accumulator.ingest(
                        samples: samples,
                        sampleRate: sample.sampleRate,
                        channelCount: Int(sample.buffer.format.channelCount)
                    )
                    await onMetrics(await accumulator.snapshot())
                }
                try ensureCurrent(requestedGeneration)
                return await accumulator.snapshot()
            } onCancel: {
                Task { await self.cancel() }
            }
            await finishOperation(requestedGeneration)
            return metrics
        } catch {
            await finishOperation(requestedGeneration)
            throw error
        }
    }

    func cancel() async {
        guard let activeGeneration else { return }
        generation &+= 1
        await finishOperation(activeGeneration)
    }

    private func ensureCurrent(_ requestedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration,
              activeGeneration == requestedGeneration else {
            throw CancellationError()
        }
    }

    private func finishOperation(_ requestedGeneration: UInt64) async {
        if providerGeneration == requestedGeneration {
            providerGeneration = nil
            await provider.stop()
        }
        if activeGeneration == requestedGeneration {
            activeGeneration = nil
        }
    }

    private static func ownedSamples(
        from buffer: AVAudioPCMBuffer
    ) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else {
            throw AudioDiagnosticLiveSignalError.unsupportedPCMFormat
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        if buffer.format.isInterleaved {
            return Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: frameCount * channelCount
                )
            )
        }

        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)
        for channel in 0..<channelCount {
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channelData[channel],
                    count: frameCount
                )
            )
        }
        return samples
    }
}

struct AudioDiagnosticSystemCaptureConfiguration: Sendable, Equatable {
    let capturesAudio = true
    let capturesMicrophone = false
    let excludesCurrentProcessAudio = false
    let excludesCurrentApplication = false
    let sampleRate = 48_000
    let channelCount = 1
}

protocol AudioDiagnosticSystemAudioSession: Sendable {
    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics
    func cancel() async
}

protocol AudioDiagnosticSystemAudioSessionCreating: Sendable {
    func makeSession(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws -> any AudioDiagnosticSystemAudioSession
}

protocol AudioDiagnosticSystemCaptureRuntime: Sendable {
    func start(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws
    func measureSignal(
        duration: TimeInterval
    ) async throws -> AudioSignalMetrics
    func stop() async
}

actor LiveSystemAudioDiagnosticSignalTester:
    AudioDiagnosticSystemSignalTesting {
    private let factory: any AudioDiagnosticSystemAudioSessionCreating
    private var activeSession: (
        generation: UInt64,
        session: any AudioDiagnosticSystemAudioSession
    )?
    private var activeGeneration: UInt64?
    private var generation: UInt64 = 0

    init(
        factory: any AudioDiagnosticSystemAudioSessionCreating =
            CoreAudioDiagnosticSessionFactory()
    ) {
        self.factory = factory
    }

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        guard activeGeneration == nil else {
            throw AudioDiagnosticLiveSignalError.alreadyRunning
        }
        generation &+= 1
        let requestedGeneration = generation
        activeGeneration = requestedGeneration

        do {
            let metrics = try await withTaskCancellationHandler {
                let session = try await factory.makeSession(
                    configuration:
                        AudioDiagnosticSystemCaptureConfiguration()
                )
                do {
                    try ensureCurrent(requestedGeneration)
                } catch {
                    await session.cancel()
                    throw error
                }
                activeSession = (requestedGeneration, session)
                return try await session.testSignal(
                    duration: duration,
                    afterCaptureStarts: afterCaptureStarts
                )
            } onCancel: {
                Task { await self.cancel(ifCurrent: requestedGeneration) }
            }
            try ensureCurrent(requestedGeneration)
            await finishOperation(requestedGeneration)
            return metrics
        } catch {
            await finishOperation(requestedGeneration)
            throw error
        }
    }

    func cancel() async {
        guard let activeGeneration else { return }
        generation &+= 1
        await finishOperation(activeGeneration)
    }

    private func cancel(ifCurrent requestedGeneration: UInt64) async {
        guard activeGeneration == requestedGeneration else { return }
        await cancel()
    }

    private func ensureCurrent(_ requestedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration,
              activeGeneration == requestedGeneration else {
            throw CancellationError()
        }
    }

    private func finishOperation(_ requestedGeneration: UInt64) async {
        if activeSession?.generation == requestedGeneration,
           let session = activeSession?.session {
            activeSession = nil
            await session.cancel()
        }
        if activeGeneration == requestedGeneration {
            activeGeneration = nil
        }
    }
}

struct CoreAudioDiagnosticSessionFactory:
    AudioDiagnosticSystemAudioSessionCreating {
    func makeSession(
        configuration: AudioDiagnosticSystemCaptureConfiguration
    ) async throws -> any AudioDiagnosticSystemAudioSession {
        SystemAudioDiagnosticSession(
            configuration: configuration,
            runtime: LiveAudioDiagnosticProcessTapRuntime()
        )
    }
}

actor SystemAudioDiagnosticSession:
    AudioDiagnosticSystemAudioSession {
    private let configuration: AudioDiagnosticSystemCaptureConfiguration
    private let runtime: any AudioDiagnosticSystemCaptureRuntime
    private var activeGeneration: UInt64?
    private var runtimeGeneration: UInt64?
    private var generation: UInt64 = 0

    init(
        configuration: AudioDiagnosticSystemCaptureConfiguration,
        runtime: any AudioDiagnosticSystemCaptureRuntime
    ) {
        self.configuration = configuration
        self.runtime = runtime
    }

    func testSignal(
        duration: TimeInterval,
        afterCaptureStarts: @escaping @Sendable () async throws -> Void
    ) async throws -> AudioSignalMetrics {
        guard activeGeneration == nil else {
            throw AudioDiagnosticLiveSignalError.alreadyRunning
        }
        generation &+= 1
        let requestedGeneration = generation
        activeGeneration = requestedGeneration
        do {
            let metrics = try await withTaskCancellationHandler {
                runtimeGeneration = requestedGeneration
                try await runtime.start(configuration: configuration)
                try ensureCurrent(requestedGeneration)
                try await afterCaptureStarts()
                try ensureCurrent(requestedGeneration)
                let metrics = try await runtime.measureSignal(
                    duration: duration
                )
                try ensureCurrent(requestedGeneration)
                return metrics
            } onCancel: {
                Task { await self.cancel(ifCurrent: requestedGeneration) }
            }
            await finishOperation(requestedGeneration)
            return metrics
        } catch {
            await finishOperation(requestedGeneration)
            throw error
        }
    }

    func cancel() async {
        guard let activeGeneration else { return }
        generation &+= 1
        await finishOperation(activeGeneration)
    }

    private func cancel(ifCurrent requestedGeneration: UInt64) async {
        guard activeGeneration == requestedGeneration else { return }
        await cancel()
    }

    private func ensureCurrent(_ requestedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration,
              activeGeneration == requestedGeneration else {
            throw CancellationError()
        }
    }

    private func finishOperation(_ requestedGeneration: UInt64) async {
        if runtimeGeneration == requestedGeneration {
            runtimeGeneration = nil
            await runtime.stop()
        }
        if activeGeneration == requestedGeneration {
            activeGeneration = nil
        }
    }
}

actor LiveAudioDiagnosticProcessTapRuntime: AudioDiagnosticSystemCaptureRuntime {
    private final class Run: @unchecked Sendable {
        let capture: any SystemAudioCaptureSession
        let completion: AsyncThrowingStream<Void, Error>
        private let continuation: AsyncThrowingStream<Void, Error>.Continuation
        private let lock = NSLock()
        private var accumulator = AudioSignalAccumulator()
        private var failure: Error?
        private var closed = false

        init(capture: any SystemAudioCaptureSession) {
            self.capture = capture
            let pair = AsyncThrowingStream<Void, Error>.makeStream()
            completion = pair.stream
            continuation = pair.continuation
        }

        func receive(_ event: SystemAudioCaptureEvent) {
            let terminalError: Error? = lock.withLock {
                guard !closed else { return nil }
                switch event {
                case let .frame(frame):
                    // Tap events arrive on the non-RT drain queue, not the
                    // AUHAL callback. Accumulate immediately, including while
                    // the one-second output tone awaits playback completion.
                    // No audio arrays or per-frame tasks are retained here.
                    accumulator.ingest(samples: frame.samples, sampleRate: frame.sampleRate,
                                       channelCount: frame.channelCount)
                    return nil
                case let .failure(error):
                    failure = error
                    closed = true
                    return error
                }
            }
            if let terminalError { continuation.finish(throwing: terminalError) }
        }

        func snapshot() throws -> AudioSignalMetrics {
            try lock.withLock {
                if let failure { throw failure }
                return accumulator.snapshot()
            }
        }

        func close() {
            let shouldFinish = lock.withLock {
                guard !closed else { return false }
                closed = true
                return true
            }
            if shouldFinish { continuation.finish(throwing: CancellationError()) }
        }
    }

    private let captureFactory: @Sendable (AudioDiagnosticSystemCaptureConfiguration) -> any SystemAudioCaptureSession
    private let observationWindow: LiveAudioDiagnosticObservationWindow
    private var activeRun: Run?

    init(
        captureFactory: @escaping @Sendable (AudioDiagnosticSystemCaptureConfiguration) -> any SystemAudioCaptureSession = {
            CoreAudioProcessTapSession(excludesCurrentProcessAudio: $0.excludesCurrentProcessAudio)
        },
        observationSleeper: any AudioDiagnosticTimeoutSleeping = ContinuousAudioDiagnosticTimeoutSleeper()
    ) {
        self.captureFactory = captureFactory
        observationWindow = LiveAudioDiagnosticObservationWindow(sleeper: observationSleeper)
    }

    func start(configuration: AudioDiagnosticSystemCaptureConfiguration) async throws {
        try Task.checkCancellation()
        guard activeRun == nil else { throw AudioDiagnosticLiveSignalError.alreadyRunning }
        let run = Run(capture: captureFactory(configuration))
        activeRun = run
        do {
            try await withTaskCancellationHandler {
                try await run.capture.start { [weak run] event in
                    run?.receive(event)
                }
                try ensureCurrent(run)
            } onCancel: {
                Task { await self.stop(run) }
            }
        } catch {
            await stop(run)
            throw error
        }
    }

    func measureSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        guard let run = activeRun else {
            throw AudioDiagnosticLiveSignalError.systemAudioCaptureNotStarted
        }
        // The stream only signals a failure/cancel; the existing observation
        // clock determines the window. Samples have already been counted.
        try await observationWindow.observe(run.completion, duration: duration) { _ in }
        try ensureCurrent(run)
        return try run.snapshot()
    }

    func stop() async {
        guard let run = activeRun else { return }
        await stop(run)
    }

    private func ensureCurrent(_ run: Run) throws {
        try Task.checkCancellation()
        guard activeRun === run else { throw CancellationError() }
    }

    private func stop(_ run: Run) async {
        guard activeRun === run else { return }
        activeRun = nil
        run.close()
        // Stop only this attempt. The process-tap session owns deferred
        // cleanup if its non-cooperative HAL startup finishes after cancel.
        await run.capture.stop()
    }
}
