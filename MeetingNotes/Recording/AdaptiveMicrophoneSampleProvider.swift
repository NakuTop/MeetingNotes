import AVFoundation
import AppKit
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

enum MicrophoneHardwareChangeEvent: Equatable, Sendable {
    case coreAudioDeviceListChanged
    case defaultInputChanged
    case avFoundationConnected(uniqueID: String)
    case avFoundationDisconnected(uniqueID: String)
    case applicationBecameActive
}

enum MicrophoneTopologyDecision: Equatable, Sendable {
    case ignore
    case rediscover
    case rediscoverClearing(Set<MicrophoneCaptureAttemptKey>)
}

enum MicrophoneHardwareChangePolicy {
    static func decision(
        event: MicrophoneHardwareChangeEvent,
        preferred: PreferredAudioInput,
        currentResolution: ResolvedMicrophoneCapture?,
        previousSnapshot: AudioInputDiscoverySnapshot,
        freshSnapshot: AudioInputDiscoverySnapshot,
        attemptedCaptures: Set<MicrophoneCaptureAttemptKey>
    ) -> MicrophoneTopologyDecision {
        let isExplicit = preferred.hasExplicitIdentity
        let freshInputs = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: freshSnapshot
        )
        let freshResolution =
            AudioInputDeviceResolver.resolveCapture(
                preferred: preferred,
                inputs: freshInputs,
                excludingAttempts: attemptedCaptures
            )

        func currentBackendAvailable() -> Bool {
            guard let currentResolution else { return false }
            switch currentResolution.plan {
            case let .avFoundation(deviceID):
                guard let deviceID else { return false }
                return freshSnapshot.avFoundationInputs.contains {
                    $0.uniqueID == deviceID && $0.isUsable
                }
            case let .coreAudio(_, uid):
                return freshSnapshot.coreAudioInputs.contains {
                    $0.uid == uid && $0.isUsable
                }
            }
        }

        func preferredAvailableInFreshSnapshot() -> Bool {
            guard isExplicit else { return false }
            if let legacyID = preferred.legacyAVFoundationID,
               freshSnapshot.avFoundationInputs.contains(where: {
                   $0.uniqueID == legacyID && $0.isUsable
               }) {
                return true
            }
            if let stableID = preferred.stableID {
                if stableID.hasPrefix("avf:"),
                   freshSnapshot.avFoundationInputs.contains(where: {
                       "avf:\($0.uniqueID)" == stableID && $0.isUsable
                   }) {
                    return true
                }
                if stableID.hasPrefix("ca:"),
                   freshSnapshot.coreAudioInputs.contains(where: {
                       "ca:\($0.uid)" == stableID && $0.isUsable
                   }) {
                    return true
                }
            }
            if let coreAudioUID = preferred.coreAudioUID,
               freshSnapshot.coreAudioInputs.contains(where: {
                   $0.uid == coreAudioUID && $0.isUsable
               }) {
                return true
            }
            return false
        }

        func preferredReappeared() -> Bool {
            guard currentResolution?.kind != .preferred else {
                return false
            }
            return preferredAvailableInFreshSnapshot()
        }

        func targetChanged() -> Bool {
            guard let currentResolution else {
                return freshResolution != nil
            }
            guard let freshResolution else {
                return true
            }
            switch (currentResolution.plan, freshResolution.plan) {
            case let (.avFoundation(currentID), .avFoundation(freshID)):
                return currentID != freshID
            case let (.coreAudio(_, currentUID), .coreAudio(_, freshUID)):
                return currentUID != freshUID
            default:
                return true
            }
        }

        func clearingKeys() -> Set<MicrophoneCaptureAttemptKey> {
            var result: Set<MicrophoneCaptureAttemptKey> = []
            if let stableID = preferred.stableID {
                result.formUnion(
                    attemptedCaptures.filter {
                        $0.physicalStableID == stableID
                    }
                )
            }
            if let legacyID = preferred.legacyAVFoundationID {
                let avfStableID = "avf:\(legacyID)"
                result.formUnion(
                    attemptedCaptures.filter {
                        $0.physicalStableID == avfStableID
                            && $0.backend == .avFoundation
                    }
                )
            }
            if let coreAudioUID = preferred.coreAudioUID {
                let caStableID = "ca:\(coreAudioUID)"
                result.formUnion(
                    attemptedCaptures.filter {
                        $0.physicalStableID == caStableID
                            && $0.backend == .coreAudioFallback
                    }
                )
            }
            return result
        }

        switch event {
        case let .avFoundationDisconnected(uniqueID):
            if case let .avFoundation(deviceID)? =
                currentResolution?.plan,
                deviceID == uniqueID {
                return .rediscover
            }
            return .ignore

        case let .avFoundationConnected(uniqueID):
            let stableID = "avf:\(uniqueID)"
            let matchesPreferred =
                preferred.legacyAVFoundationID == uniqueID
                || preferred.stableID == stableID
            if isExplicit, matchesPreferred, preferredReappeared() {
                let cleared = attemptedCaptures.filter {
                    $0.backend == .avFoundation
                        && $0.physicalStableID == stableID
                }
                return .rediscoverClearing(Set(cleared))
            }
            return .ignore

        case .coreAudioDeviceListChanged:
            if preferredReappeared() {
                return .rediscoverClearing(clearingKeys())
            }
            if currentBackendAvailable() {
                return .ignore
            }
            return .rediscover

        case .defaultInputChanged:
            if isExplicit {
                if currentResolution?.kind == .preferred,
                   currentBackendAvailable() {
                    return .ignore
                }
                if preferredReappeared() {
                    return .rediscoverClearing(clearingKeys())
                }
                return .ignore
            }
            return targetChanged() ? .rediscover : .ignore

        case .applicationBecameActive:
            if !currentBackendAvailable() {
                return .rediscover
            }
            if preferredReappeared() {
                return .rediscoverClearing(clearingKeys())
            }
            if !isExplicit, targetChanged() {
                return .rediscover
            }
            return .ignore
        }
    }
}

private extension PreferredAudioInput {
    var hasExplicitIdentity: Bool {
        !(stableID?.isEmpty ?? true)
            || !(legacyAVFoundationID?.isEmpty ?? true)
            || !(coreAudioUID?.isEmpty ?? true)
    }
}

struct MicrophoneSampleTimelineNormalizer: Sendable {
    private var backendOriginSeconds: TimeInterval?
    private var backendSessionOrigin: TimeInterval = 0
    private var nextSessionTimestamp: TimeInterval = 0

    mutating func reset() {
        backendOriginSeconds = nil
        backendSessionOrigin = 0
        nextSessionTimestamp = 0
    }

    mutating func beginBackend() {
        backendOriginSeconds = nil
        backendSessionOrigin = nextSessionTimestamp
    }

    mutating func normalize(
        _ sample: MicrophoneSample
    ) -> MicrophoneSample {
        let rawSeconds: TimeInterval
        if sample.sampleRate.isFinite, sample.sampleRate > 0 {
            rawSeconds =
                Double(sample.sampleTime) / sample.sampleRate
        } else {
            rawSeconds = 0
        }

        if backendOriginSeconds == nil {
            backendOriginSeconds = rawSeconds
        }
        let origin = backendOriginSeconds ?? rawSeconds
        let calculatedTimestamp =
            backendSessionOrigin + max(0, rawSeconds - origin)
        let timestamp = max(nextSessionTimestamp, calculatedTimestamp)

        let frameDuration: TimeInterval
        let formatSampleRate = sample.buffer.format.sampleRate
        if formatSampleRate.isFinite, formatSampleRate > 0 {
            frameDuration =
                Double(sample.buffer.frameLength) / formatSampleRate
        } else if sample.sampleRate.isFinite, sample.sampleRate > 0 {
            frameDuration =
                Double(sample.buffer.frameLength) / sample.sampleRate
        } else {
            frameDuration = 0
        }
        nextSessionTimestamp = max(
            nextSessionTimestamp,
            timestamp + frameDuration
        )

        return MicrophoneSample(
            buffer: sample.buffer,
            sampleTime: sample.sampleTime,
            sampleRate: sample.sampleRate,
            timestamp: timestamp
        )
    }
}

protocol CoreAudioInputHardwareObserving: Sendable {
    func events() -> AsyncStream<MicrophoneHardwareChangeEvent>
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
        case rediscoveryNeeded(
            clearedAttempts: Set<MicrophoneCaptureAttemptKey>
        )
        case terminalFailure(BackendFailure)
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
    private var attemptedCaptures:
        Set<MicrophoneCaptureAttemptKey> = []
    private var lastDiscoverySnapshot: AudioInputDiscoverySnapshot?
    private var lastBackendError: Error?
    private var timelineNormalizer =
        MicrophoneSampleTimelineNormalizer()
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
        attemptedCaptures = []
        lastDiscoverySnapshot = nil
        lastBackendError = nil
        backendFrameCount = 0
        timelineNormalizer.reset()
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
        let task = runTask
        runTask = nil
        task?.cancel()
        let provider = currentProvider
        currentProvider = nil
        await provider?.stop()
        await task?.value
        relay?.finish()
        relay = nil
        isPaused = false
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
            let permissionStatus = permission.status()
            runtime.telemetry.microphonePermission = permissionStatus
            guard permissionStatus == .authorized else {
                finish(
                    token: token,
                    throwing: Self.permissionError(
                        for: permissionStatus
                    )
                )
                return
            }
            runtime.status = .permissionAuthorized
            do {
                let snapshot = try discovery.discover()
                lastDiscoverySnapshot = snapshot
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
                        excludingAttempts: attemptedCaptures
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
                    preferred: preferred,
                    token: token
                )
                switch outcome {
                case .completed, .cancelled:
                    finish(token: token)
                    return
                case let .rediscoveryNeeded(clearedAttempts):
                    if !clearedAttempts.isEmpty {
                        attemptedCaptures.subtract(clearedAttempts)
                    }
                    continue
                case let .terminalFailure(failure):
                    finish(token: token, throwing: failure.error)
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
        preferred: PreferredAudioInput,
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
            for await event in changeEvents {
                guard let self,
                      await self.activeToken == token else { break }
                let permissionStatus = self.permission.status()
                guard permissionStatus == .authorized else {
                    outcomeContinuation.yield(
                        .terminalFailure(
                            BackendFailure(
                                error: Self.permissionError(
                                    for: permissionStatus
                                )
                            )
                        )
                    )
                    break
                }
                let decision = await self.hardwareDecision(
                    for: event,
                    preferred: preferred,
                    currentResolution: resolution,
                    token: token
                )
                switch decision {
                case .ignore:
                    break
                case .rediscover:
                    outcomeContinuation.yield(
                        .rediscoveryNeeded(clearedAttempts: [])
                    )
                case let .rediscoverClearing(clearedAttempts):
                    outcomeContinuation.yield(
                        .rediscoveryNeeded(
                            clearedAttempts: clearedAttempts
                        )
                    )
                }
            }
        }

        let stream: AsyncThrowingStream<MicrophoneSample, Error>
        do {
            stream = try await provider.start(deviceID: deviceID)
            runtime.telemetry.captureStarted = true
            timelineNormalizer.beginBackend()
        } catch {
            changeTask.cancel()
            runtime.status = .captureStartFailed
            if activeToken == token {
                await provider.stop()
                currentProvider = nil
            }
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
        if activeToken == token {
            await provider.stop()
            currentProvider = nil
        }
        return outcome
    }

    private func hardwareDecision(
        for event: MicrophoneHardwareChangeEvent,
        preferred: PreferredAudioInput,
        currentResolution: ResolvedMicrophoneCapture,
        token: UUID
    ) async -> MicrophoneTopologyDecision {
        guard activeToken == token else { return .ignore }
        do {
            let snapshot = try discovery.discover()
            let previousSnapshot =
                lastDiscoverySnapshot ?? snapshot
            lastDiscoverySnapshot = snapshot
            return MicrophoneHardwareChangePolicy.decision(
                event: event,
                preferred: preferred,
                currentResolution: currentResolution,
                previousSnapshot: previousSnapshot,
                freshSnapshot: snapshot,
                attemptedCaptures: attemptedCaptures
            )
        } catch {
            return .rediscover
        }
    }

    private static func permissionError(
        for status: CapturePermissionStatus
    ) -> MicrophoneCaptureError {
        switch status {
        case .authorized:
            return .permissionDenied
        case .notDetermined:
            return .permissionNotDetermined
        case .denied, .unavailable:
            return .permissionDenied
        case .restricted:
            return .permissionRestricted
        }
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
        let normalizedSample = timelineNormalizer.normalize(sample)
        relay?.yield(normalizedSample)
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
        attemptedCaptures.insert(resolution.attemptKey)
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
    private var continuations:
        [UUID: AsyncStream<MicrophoneHardwareChangeEvent>.Continuation] =
            [:]
    private var listener: AudioObjectPropertyListenerBlock?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var isObserving = false

    deinit {
        stopObserving()
    }

    func events() -> AsyncStream<MicrophoneHardwareChangeEvent> {
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
        let listener: AudioObjectPropertyListenerBlock = {
            [weak self] _, addresses in
            self?.handleCoreAudioChange(
                selector: addresses.pointee.mSelector
            )
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
        let notificationCenter = NotificationCenter.default
        notificationTokens = [
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let device =
                    notification.object as? AVCaptureDevice,
                    device.hasMediaType(.audio) else {
                    return
                }
                self?.notify(
                    .avFoundationConnected(
                        uniqueID: device.uniqueID
                    )
                )
            },
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let device =
                    notification.object as? AVCaptureDevice,
                    device.hasMediaType(.audio) else {
                    return
                }
                self?.notify(
                    .avFoundationDisconnected(
                        uniqueID: device.uniqueID
                    )
                )
            },
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.notify(.applicationBecameActive)
            },
        ]
        isObserving = !registered.isEmpty || !notificationTokens.isEmpty
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
        let tokens = notificationTokens
        notificationTokens = []
        isObserving = false
        lock.unlock()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func handleCoreAudioChange(
        selector: AudioObjectPropertySelector
    ) {
        let event: MicrophoneHardwareChangeEvent
        switch selector {
        case kAudioHardwarePropertyDevices:
            event = .coreAudioDeviceListChanged
        case kAudioHardwarePropertyDefaultInputDevice:
            event = .defaultInputChanged
        default:
            return
        }
        notify(event)
    }

    private func notify(_ event: MicrophoneHardwareChangeEvent) {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(event) }
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
