import AVFoundation
import CoreAudio
import Foundation

enum CoreAudioMicrophoneSessionEvent: @unchecked Sendable {
    case buffer(AVAudioPCMBuffer, AVAudioFramePosition, Double)
    case failure(Error)
}

protocol CoreAudioMicrophoneSessionManaging: Sendable {
    func configure(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) async throws
    func start() async throws
    func pause() async
    func resume() async throws
    func stop() async
}

protocol CoreAudioDeviceIDResolving: Sendable {
    func resolve(deviceID: String?) throws -> AudioDeviceID
}

struct LiveCoreAudioDeviceIDResolver: CoreAudioDeviceIDResolving {
    private let inputsProvider:
        @Sendable () throws -> [CoreAudioInputDevice]

    init(
        inputsProvider:
            @escaping @Sendable () throws -> [CoreAudioInputDevice] = {
                try CoreAudioDeviceProvider.inputDevices()
            }
    ) {
        self.inputsProvider = inputsProvider
    }

    func resolve(deviceID: String?) throws -> AudioDeviceID {
        let inputs = try inputsProvider()
        if let requestedUID = deviceID {
            guard let exactMatch = inputs.first(where: {
                $0.uid == requestedUID && $0.isUsable
            }) else {
                throw MicrophoneCaptureError.selectedDeviceUnavailable
            }
            return exactMatch.deviceID
        }
        if let systemDefault = inputs.first(where: {
            $0.isSystemDefault && $0.isUsable
        }) {
            return systemDefault.deviceID
        }
        if let firstUsable = inputs.first(where: \.isUsable) {
            return firstUsable.deviceID
        }
        throw MicrophoneCaptureError.noUsableInputDevice
    }
}

actor CoreAudioMicrophoneSampleProvider: MicrophoneSampleProviding {
    static let productionBufferCapacity = 64

    private let session: any CoreAudioMicrophoneSessionManaging
    private let resolver: any CoreAudioDeviceIDResolving
    private let bufferCapacity: Int
    private var relay: CoreAudioMicrophoneSampleRelay?
    private var activeToken: UUID?
    private var isPaused = false

    init(
        session: any CoreAudioMicrophoneSessionManaging =
            LiveCoreAudioMicrophoneSession(),
        resolver: any CoreAudioDeviceIDResolving =
            LiveCoreAudioDeviceIDResolver(),
        bufferCapacity: Int =
            CoreAudioMicrophoneSampleProvider.productionBufferCapacity
    ) {
        self.session = session
        self.resolver = resolver
        self.bufferCapacity = max(1, bufferCapacity)
    }

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        guard activeToken == nil else {
            throw AudioCaptureError.alreadyRunning
        }
        let pair = AsyncThrowingStream<MicrophoneSample, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferCapacity)
        )
        let token = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.handleStreamTermination(token: token)
            }
        }
        let relay = CoreAudioMicrophoneSampleRelay(
            continuation: pair.continuation,
            onTerminal: { [weak self] in
                Task {
                    await self?.handleStreamTermination(token: token)
                }
            }
        )
        activeToken = token
        self.relay = relay
        isPaused = false

        do {
            try Task.checkCancellation()
            let resolvedDeviceID = try resolver.resolve(deviceID: deviceID)
            try ensureStartIsCurrent(token: token)
            try await session.configure(
                deviceID: resolvedDeviceID,
                eventHandler: { event in
                    relay.receive(event)
                }
            )
            try ensureStartIsCurrent(token: token)
            try await session.start()
            try ensureStartIsCurrent(token: token)
        } catch {
            guard activeToken == token else {
                let cancellation = CancellationError()
                relay.finish(throwing: cancellation)
                throw cancellation
            }
            activeToken = nil
            self.relay = nil
            isPaused = false
            relay.finish(throwing: error)
            await session.stop()
            throw error
        }
        return pair.stream
    }

    func pause() async throws {
        guard let token = activeToken else {
            throw AudioCaptureError.notRunning
        }
        guard !isPaused else { return }
        await session.pause()
        guard activeToken == token else {
            throw CancellationError()
        }
        isPaused = true
    }

    func resume() async throws {
        guard let token = activeToken else {
            throw AudioCaptureError.notRunning
        }
        guard isPaused else { return }
        try await session.resume()
        guard activeToken == token else {
            throw CancellationError()
        }
        isPaused = false
    }

    func stop() async {
        guard activeToken != nil else { return }
        activeToken = nil
        isPaused = false
        let relay = self.relay
        self.relay = nil
        relay?.finish()
        await session.stop()
    }

    private func handleStreamTermination(token: UUID) async {
        guard activeToken == token else { return }
        activeToken = nil
        isPaused = false
        relay = nil
        await session.stop()
    }

    private func ensureStartIsCurrent(token: UUID) throws {
        try Task.checkCancellation()
        guard activeToken == token else {
            throw CancellationError()
        }
    }
}

private final class CoreAudioMicrophoneSampleRelay:
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

    func receive(_ event: CoreAudioMicrophoneSessionEvent) {
        var terminalFailure = false
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        switch event {
        case let .buffer(buffer, sampleTime, sampleRate):
            let result = continuation.yield(
                MicrophoneSample(
                    buffer: buffer,
                    sampleTime: sampleTime,
                    sampleRate: sampleRate
                )
            )
            switch result {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.finish(
                    throwing:
                        MicrophoneCaptureError
                            .backlogCapacityExceeded
                )
                self.continuation = nil
                terminalFailure = true
            @unknown default:
                continuation.finish(
                    throwing:
                        MicrophoneCaptureError
                            .backlogCapacityExceeded
                )
                self.continuation = nil
                terminalFailure = true
            }
        case let .failure(error):
            continuation.finish(throwing: error)
            self.continuation = nil
            terminalFailure = true
        }
        lock.unlock()
        if terminalFailure {
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
