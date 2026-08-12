import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneRecoveryConfiguration: Equatable, Sendable {
    var firstFrameTimeout: Duration
    var maxAutomaticRecoveryAttempts: Int

    static let production = MicrophoneRecoveryConfiguration(
        firstFrameTimeout: .milliseconds(1_500),
        maxAutomaticRecoveryAttempts: 2
    )
}

protocol CoreAudioInputHardwareObserving: Sendable {
    func events() -> AsyncStream<Void>
}

struct LiveMicrophonePermissionChecker: MicrophonePermissionChecking {
    func status() -> CapturePermissionStatus {
        CapturePermissionStatus(
            AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }
}

actor AdaptiveMicrophoneSampleProvider:
    MicrophoneSampleProviding,
    MicrophoneRuntimeReporting {
    static let productionBufferCapacity = 64

    private struct BackendFailure: @unchecked Sendable {
        let error: Error
    }

    private enum BackendOutcome: Sendable {
        case completed
        case recoveryNeeded(BackendFailure)
        case cancelled
    }

    private let avFoundationProvider: any MicrophoneSampleProviding
    private let coreAudioProvider: any MicrophoneSampleProviding
    private let discovery: any AudioInputDeviceProviding
    private let permission: any MicrophonePermissionChecking
    private let preferredInputProvider: @Sendable () -> PreferredAudioInput
    private let hardwareObserver: any CoreAudioInputHardwareObserving
    private let configuration: MicrophoneRecoveryConfiguration
    private let bufferCapacity: Int

    private var activeToken: UUID?
    private var relay: AdaptiveMicrophoneSampleRelay?
    private var runTask: Task<Void, Never>?
    private var currentProvider: (any MicrophoneSampleProviding)?
    private var isPaused = false
    private var backendFrameCount = 0
    private var attemptedDeviceIDs: Set<String> = []
    private var excludedBackend: MicrophoneCaptureBackend?
    private var lastBackendError: Error?
    private var runtime = MicrophoneRuntimeSnapshot()

    init(
        avFoundationProvider: any MicrophoneSampleProviding =
            AVCaptureMicrophoneSampleProvider(),
        coreAudioProvider: any MicrophoneSampleProviding =
            CoreAudioMicrophoneSampleProvider(),
        discovery: any AudioInputDeviceProviding =
            LiveAudioInputDeviceProvider(),
        permission: any MicrophonePermissionChecking =
            LiveMicrophonePermissionChecker(),
        preferredInputProvider:
            @escaping @Sendable () -> PreferredAudioInput = {
                PreferredAudioInputPersistence.load(defaults: .standard)
            },
        hardwareObserver: any CoreAudioInputHardwareObserving =
            LiveCoreAudioInputHardwareObserver(),
        configuration: MicrophoneRecoveryConfiguration = .production,
        bufferCapacity: Int =
            AdaptiveMicrophoneSampleProvider.productionBufferCapacity
    ) {
        self.avFoundationProvider = avFoundationProvider
        self.coreAudioProvider = coreAudioProvider
        self.discovery = discovery
        self.permission = permission
        self.preferredInputProvider = preferredInputProvider
        self.hardwareObserver = hardwareObserver
        self.configuration = configuration
        self.bufferCapacity = max(1, bufferCapacity)
        runtime.telemetry = Self.makeInitialTelemetry()
    }

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        guard activeToken == nil else {
            throw AudioCaptureError.alreadyRunning
        }
        let permissionStatus = permission.status()
        runtime.telemetry.microphonePermission = permissionStatus
        switch permissionStatus {
        case .authorized:
            runtime.status = .permissionAuthorized
        case .notDetermined:
            runtime.status = .permissionNotDetermined
            throw MicrophoneCaptureError.permissionNotDetermined
        case .denied:
            runtime.status = .permissionDenied
            throw MicrophoneCaptureError.permissionDenied
        case .restricted:
            runtime.status = .permissionRestricted
            throw MicrophoneCaptureError.permissionRestricted
        case .unavailable:
            runtime.status = .permissionDenied
            throw MicrophoneCaptureError.permissionDenied
        }

        let pair = AsyncThrowingStream<MicrophoneSample, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferCapacity)
        )
        let token = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.handleTermination(token: token)
            }
        }
        let relay = AdaptiveMicrophoneSampleRelay(
            continuation: pair.continuation,
            onTerminal: { [weak self] in
                Task {
                    await self?.handleTermination(token: token)
                }
            }
        )
        activeToken = token
        self.relay = relay
        isPaused = false
        attemptedDeviceIDs = []
        excludedBackend = nil
        lastBackendError = nil
        backendFrameCount = 0
        runTask = Task { [weak self] in
            await self?.recoveryLoop(
                token: token,
                deviceIDOverride: deviceID
            )
        }
        return pair.stream
    }

    func pause() async throws {
        guard activeToken != nil else {
            throw AudioCaptureError.notRunning
        }
        guard !isPaused else { return }
        try await currentProvider?.pause()
        isPaused = true
    }

    func resume() async throws {
        guard activeToken != nil else {
            throw AudioCaptureError.notRunning
        }
        guard isPaused else { return }
        try await currentProvider?.resume()
        isPaused = false
    }

    func stop() async {
        guard activeToken != nil else { return }
        activeToken = nil
        runtime.status = .stopped
        runTask?.cancel()
        runTask = nil
        relay?.finish()
        relay = nil
        await currentProvider?.stop()
        currentProvider = nil
    }

    func runtimeSnapshot() async -> MicrophoneRuntimeSnapshot {
        runtime
    }

    private func recoveryLoop(
        token: UUID,
        deviceIDOverride: String?
    ) async {
        var attempts = 0
        let maxAttempts = max(0, configuration.maxAutomaticRecoveryAttempts)
        while activeToken == token {
            guard !Task.isCancelled else {
                finish(token: token)
                return
            }
            do {
                let snapshot = try discovery.discover()
                let inputs = AudioInputDeviceIdentityMatcher.mergedInputs(
                    from: snapshot
                )
                let preferred: PreferredAudioInput
                if let deviceIDOverride {
                    preferred = PreferredAudioInput(
                        backend: .automatic,
                        stableID: deviceIDOverride,
                        legacyAVFoundationID: deviceIDOverride,
                        coreAudioUID: nil
                    )
                } else {
                    preferred = preferredInputProvider()
                }
                guard let resolution =
                    AudioInputDeviceResolver.resolveCapture(
                        preferred: preferred,
                        inputs: inputs,
                        excludingDeviceIDs: attemptedDeviceIDs,
                        excludingBackend: excludedBackend
                    ) else {
                    throw lastBackendError
                        ?? MicrophoneCaptureError.noUsableInputDevice
                }
                MicrophoneDiagnosticLogger.discovery(
                    permission: runtime.telemetry.microphonePermission,
                    avFoundationInputCount:
                        snapshot.avFoundationInputCount,
                    coreAudioInputCount:
                        snapshot.coreAudioInputCount,
                    avFoundationDefaultAvailable:
                        snapshot.avFoundationDefaultAvailable,
                    coreAudioDefaultAvailable:
                        snapshot.coreAudioDefaultAvailable
                )
                updateTelemetry(
                    with: snapshot,
                    resolution: resolution,
                    attempts: attempts
                )
                let outcome = await runBackend(
                    resolution: resolution,
                    token: token
                )
                switch outcome {
                case .completed, .cancelled:
                    finish(token: token)
                    return
                case let .recoveryNeeded(failure):
                    recordFailure(
                        of: resolution,
                        error: failure.error
                    )
                    MicrophoneDiagnosticLogger.captureFailure(
                        category: category(for: failure.error)
                    )
                    runtime.telemetry.lastCaptureErrorCategory =
                        category(for: failure.error)
                    guard attempts < maxAttempts,
                          activeToken == token else {
                        finish(token: token, throwing: failure.error)
                        return
                    }
                    attempts += 1
                    runtime.telemetry.automaticRecoveryAttemptCount = attempts
                    runtime.status = .recovering
                    MicrophoneDiagnosticLogger.recoveryStarted(
                        attempt: attempts
                    )
                    try? await Task.sleep(for: .milliseconds(20))
                }
            } catch is CancellationError {
                finish(token: token)
                return
            } catch {
                lastBackendError = error
                runtime.telemetry.lastCaptureErrorCategory =
                    category(for: error)
                guard attempts < maxAttempts,
                      activeToken == token else {
                    finish(token: token, throwing: error)
                    return
                }
                attempts += 1
                runtime.telemetry.automaticRecoveryAttemptCount = attempts
                runtime.status = .recovering
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func runBackend(
        resolution: ResolvedMicrophoneCapture,
        token: UUID
    ) async -> BackendOutcome {
        let provider: any MicrophoneSampleProviding
        let deviceID: String?
        switch resolution.plan {
        case let .avFoundation(id):
            provider = avFoundationProvider
            deviceID = id
            runtime.status = .avFoundationDeviceAvailable
            runtime.telemetry.captureBackend = .avFoundation
        case let .coreAudio(_, uid):
            provider = coreAudioProvider
            deviceID = uid
            runtime.status = .fallbackActive
            runtime.telemetry.captureBackend = .coreAudioFallback
            MicrophoneDiagnosticLogger.fallbackStarted()
        }
        currentProvider = provider
        backendFrameCount = 0
        runtime.telemetry.captureStarted = false

        let pair = AsyncStream<BackendOutcome>.makeStream()
        let outcomeContinuation = pair.continuation

        let changeEvents = hardwareObserver.events()
        let changeTask = Task { [weak self] in
            for await _ in changeEvents {
                guard let self,
                      await self.activeToken == token else { break }
                outcomeContinuation.yield(
                    .recoveryNeeded(
                        BackendFailure(
                            error: MicrophoneCaptureError
                                .deviceDisconnected
                        )
                    )
                )
            }
        }

        let stream: AsyncThrowingStream<MicrophoneSample, Error>
        do {
            stream = try await provider.start(deviceID: deviceID)
            runtime.telemetry.captureStarted = true
        } catch {
            changeTask.cancel()
            runtime.status = .captureStartFailed
            await provider.stop()
            return .recoveryNeeded(BackendFailure(error: error))
        }

        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: self?.configuration.firstFrameTimeout
                        ?? .milliseconds(1_500)
                )
            } catch {
                return
            }
            guard let self, await self.activeToken == token else { return }
            if await self.backendFrameCount == 0 {
                outcomeContinuation.yield(
                    .recoveryNeeded(
                        BackendFailure(
                            error: MicrophoneCaptureError.captureNoFrames
                        )
                    )
                )
            }
        }

        let consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await sample in stream {
                    guard await self.activeToken == token else { break }
                    await self.ingest(sample)
                }
                outcomeContinuation.yield(
                    .recoveryNeeded(
                        BackendFailure(
                            error: MicrophoneCaptureError.runtimeFailure
                        )
                    )
                )
            } catch {
                outcomeContinuation.yield(
                    .recoveryNeeded(BackendFailure(error: error))
                )
            }
        }

        let outcome = await pair.stream.first(where: { _ in true })
            ?? .cancelled
        outcomeContinuation.finish()
        consumeTask.cancel()
        watchdog.cancel()
        changeTask.cancel()
        await provider.stop()
        currentProvider = nil
        return outcome
    }

    private func ingest(_ sample: MicrophoneSample) {
        backendFrameCount += 1
        if runtime.telemetry.receivedFrameCount == 0 {
            MicrophoneDiagnosticLogger.firstFrameReceived()
        }
        runtime.telemetry.receivedFrameCount += 1
        runtime.telemetry.sampleRate = sample.sampleRate
        runtime.telemetry.channelCount = Int(
            sample.buffer.format.channelCount
        )
        relay?.yield(sample)
    }

    private func updateTelemetry(
        with snapshot: AudioInputDiscoverySnapshot,
        resolution: ResolvedMicrophoneCapture,
        attempts: Int
    ) {
        runtime.telemetry.avFoundationInputCount =
            snapshot.avFoundationInputCount
        runtime.telemetry.coreAudioInputCount =
            snapshot.coreAudioInputCount
        runtime.telemetry.avFoundationDefaultAvailable =
            snapshot.avFoundationDefaultAvailable
        runtime.telemetry.coreAudioDefaultAvailable =
            snapshot.coreAudioDefaultAvailable
        runtime.telemetry.preferredDeviceAvailable =
            resolution.kind == .preferred
        runtime.telemetry.selectedInputBackend =
            resolution.plan.backend
        runtime.telemetry.automaticRecoveryAttemptCount = attempts
    }

    private func recordFailure(
        of resolution: ResolvedMicrophoneCapture,
        error: Error
    ) {
        lastBackendError = error
        switch resolution.plan {
        case let .avFoundation(deviceID):
            if let deviceID {
                attemptedDeviceIDs.insert(deviceID)
            } else {
                attemptedDeviceIDs.insert("avf:system-default")
            }
            excludedBackend = nil
        case let .coreAudio(_, uid):
            attemptedDeviceIDs.insert(uid)
            excludedBackend = .coreAudioFallback
        }
    }

    private func finish(token: UUID, throwing error: Error? = nil) {
        guard activeToken == token else { return }
        activeToken = nil
        runTask = nil
        let relay = self.relay
        self.relay = nil
        relay?.finish(throwing: error)
        runtime.status = error == nil ? .stopped : .failed
    }

    private func handleTermination(token: UUID) async {
        guard activeToken == token else { return }
        await stop()
    }

    private func category(
        for error: Error
    ) -> MicrophoneCaptureErrorCategory? {
        switch error as? MicrophoneCaptureError {
        case .permissionNotDetermined:
            return .permissionNotDetermined
        case .permissionDenied:
            return .permissionDenied
        case .permissionRestricted:
            return .permissionRestricted
        case .unableToConfigureDevice:
            return .configurationFailed
        case .unableToStartSession:
            return .startFailed
        case .captureNoFrames:
            return .noFrames
        case .deviceDisconnected:
            return .deviceDisconnected
        case .selectedDeviceUnavailable,
             .defaultDeviceUnavailable,
             .noUsableInputDevice:
            return .noUsableInputDevice
        case .backlogCapacityExceeded, .runtimeFailure:
            return .runtimeFailure
        case nil:
            return nil
        }
    }

    private static func makeInitialTelemetry()
        -> MicrophoneCaptureTelemetry {
        var telemetry = MicrophoneCaptureTelemetry()
        let bundle = Bundle.main
        telemetry.appVersion =
            bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? ""
        telemetry.buildNumber =
            bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? ""
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        telemetry.macOSVersion = [
            systemVersion.majorVersion,
            systemVersion.minorVersion,
            systemVersion.patchVersion
        ].map(String.init).joined(separator: ".")
        #if arch(arm64)
        telemetry.architecture = "arm64"
        #else
        telemetry.architecture = "x86_64"
        #endif
        return telemetry
    }
}

private final class AdaptiveMicrophoneSampleRelay:
    @unchecked Sendable {
    private let lock = NSLock()
    private let onTerminal: @Sendable () -> Void
    private var continuation:
        AsyncThrowingStream<MicrophoneSample, Error>.Continuation?

    init(
        continuation:
            AsyncThrowingStream<MicrophoneSample, Error>.Continuation,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onTerminal = onTerminal
    }

    func yield(_ sample: MicrophoneSample) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        switch continuation.yield(sample) {
        case .enqueued:
            lock.unlock()
        case .dropped, .terminated:
            continuation.finish(
                throwing: MicrophoneCaptureError.backlogCapacityExceeded
            )
            self.continuation = nil
            lock.unlock()
            onTerminal()
        @unknown default:
            continuation.finish(
                throwing: MicrophoneCaptureError.backlogCapacityExceeded
            )
            self.continuation = nil
            lock.unlock()
            onTerminal()
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        lock.unlock()
    }
}

final class LiveCoreAudioInputHardwareObserver:
    CoreAudioInputHardwareObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(
        label: "MeetingNotes.audio-input-changes"
    )
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var listener: AudioObjectPropertyListenerBlock?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []
    private var isObserving = false

    func events() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            startObserving()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    private func startObserving() {
        lock.lock()
        guard !isObserving else {
            lock.unlock()
            return
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notify()
        }
        var registered: [AudioObjectPropertyAddress] = []
        for address in Self.observedAddresses {
            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &mutableAddress,
                callbackQueue,
                listener
            )
            if status == noErr {
                registered.append(address)
            }
        }
        self.listener = listener
        registeredAddresses = registered
        isObserving = !registered.isEmpty
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        let hasSubscribers = !continuations.isEmpty
        lock.unlock()
        if !hasSubscribers {
            stopObserving()
        }
    }

    private func stopObserving() {
        lock.lock()
        guard let listener else {
            lock.unlock()
            return
        }
        for address in registeredAddresses {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &mutableAddress,
                callbackQueue,
                listener
            )
        }
        self.listener = nil
        registeredAddresses = []
        isObserving = false
        lock.unlock()
    }

    private func notify() {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(()) }
    }

    private static let observedAddresses = [
        propertyAddress(selector: kAudioHardwarePropertyDevices),
        propertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
    ]

    private static func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
