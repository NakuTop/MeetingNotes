import AVFoundation
import CoreMedia
import Foundation

enum AVCaptureMicrophoneSessionEvent: @unchecked Sendable {
    case sampleBuffer(CMSampleBuffer)
    case failure(Error)
}

protocol AVCaptureMicrophoneSessionManaging: Sendable {
    func configure(
        deviceID: String?,
        eventHandler:
            @escaping @Sendable (AVCaptureMicrophoneSessionEvent) -> Void
    ) async throws
    func start() async throws
    func pause() async
    func resume() async throws
    func stop() async
}

actor AVCaptureMicrophoneSampleProvider: MicrophoneSampleProviding {
    static let productionBufferCapacity = 64

    private let session: any AVCaptureMicrophoneSessionManaging
    private let decoder: any AudioSampleBufferDecoding
    private let bufferCapacity: Int
    private var relay: AVCaptureMicrophoneSampleRelay?
    private var activeToken: UUID?
    private var isPaused = false

    init(
        session: any AVCaptureMicrophoneSessionManaging =
            LiveAVCaptureMicrophoneSession(),
        bufferCapacity: Int =
            AVCaptureMicrophoneSampleProvider.productionBufferCapacity,
        decoder: any AudioSampleBufferDecoding =
            AudioSampleBufferDecoder()
    ) {
        self.session = session
        self.bufferCapacity = max(1, bufferCapacity)
        self.decoder = decoder
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
        let relay = AVCaptureMicrophoneSampleRelay(
            continuation: pair.continuation,
            decoder: decoder,
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
            try await session.configure(
                deviceID: deviceID,
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

private final class AVCaptureMicrophoneSampleRelay:
    @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: any AudioSampleBufferDecoding
    private let onTerminal: @Sendable () -> Void
    private var continuation:
        AsyncThrowingStream<MicrophoneSample, Error>.Continuation?

    init(
        continuation:
            AsyncThrowingStream<MicrophoneSample, Error>.Continuation,
        decoder: any AudioSampleBufferDecoding,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.decoder = decoder
        self.onTerminal = onTerminal
    }

    func receive(_ event: AVCaptureMicrophoneSessionEvent) {
        var terminalFailure = false
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        switch event {
        case let .sampleBuffer(sampleBuffer):
            do {
                let decoded = try decoder.decode(sampleBuffer)
                let result = continuation.yield(
                    MicrophoneSample(
                        buffer: decoded.buffer,
                        sampleTime: decoded.sampleTime,
                        sampleRate: decoded.sampleRate
                    )
                )
                switch result {
                case .enqueued:
                    break
                case .dropped:
                    continuation.finish(
                        throwing:
                            MicrophoneCaptureError
                                .backlogCapacityExceeded
                    )
                    self.continuation = nil
                    terminalFailure = true
                case .terminated:
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
            } catch {
                continuation.finish(throwing: error)
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

private protocol AVCaptureMicrophoneDeviceResolving: Sendable {
    func resolve(deviceID: String?) -> AVCaptureDevice?
}

private struct SystemAVCaptureMicrophoneDeviceResolver:
    AVCaptureMicrophoneDeviceResolving {
    func resolve(deviceID: String?) -> AVCaptureDevice? {
        if let deviceID {
            return AVCaptureDevice(uniqueID: deviceID)
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

private final class LiveAVCaptureMicrophoneSession:
    NSObject,
    AVCaptureMicrophoneSessionManaging,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let session = AVCaptureSession()
    private let resolver: any AVCaptureMicrophoneDeviceResolving
    private let sessionQueue = DispatchQueue(
        label: "MeetingNotes.microphone.session"
    )
    private let sampleQueue = DispatchQueue(
        label: "MeetingNotes.microphone.samples"
    )
    private let handlerLock = NSLock()
    private var eventHandler:
        (@Sendable (AVCaptureMicrophoneSessionEvent) -> Void)?
    private var configuredDevice: AVCaptureDevice?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        resolver: any AVCaptureMicrophoneDeviceResolving =
            SystemAVCaptureMicrophoneDeviceResolver()
    ) {
        self.resolver = resolver
    }

    func configure(
        deviceID: String?,
        eventHandler:
            @escaping @Sendable (AVCaptureMicrophoneSessionEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureOnSessionQueue(
                        deviceID: deviceID,
                        eventHandler: eventHandler
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await setRunning(true)
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func resume() async throws {
        try await setRunning(true)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopOnSessionQueue()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _ = output
        _ = connection
        send(.sampleBuffer(sampleBuffer))
    }

    private func configureOnSessionQueue(
        deviceID: String?,
        eventHandler:
            @escaping @Sendable (AVCaptureMicrophoneSessionEvent) -> Void
    ) throws {
        stopOnSessionQueue()
        guard let device = resolver.resolve(deviceID: deviceID) else {
            throw deviceID == nil
                ? MicrophoneCaptureError.defaultDeviceUnavailable
                : MicrophoneCaptureError.selectedDeviceUnavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw deviceID == nil
                ? MicrophoneCaptureError.unableToConfigureDevice
                : MicrophoneCaptureError.selectedDeviceUnavailable
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            output.setSampleBufferDelegate(nil, queue: nil)
            throw MicrophoneCaptureError.unableToConfigureDevice
        }
        session.addInput(input)
        session.addOutput(output)
        configuredDevice = device
        setEventHandler(eventHandler)
        registerNotifications(for: device)
    }

    private func setRunning(_ shouldRun: Bool) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                if shouldRun, !session.isRunning {
                    session.startRunning()
                }
                guard !shouldRun || session.isRunning else {
                    continuation.resume(
                        throwing:
                            MicrophoneCaptureError
                                .unableToStartSession
                    )
                    return
                }
                continuation.resume()
            }
        }
    }

    private func stopOnSessionQueue() {
        if session.isRunning {
            session.stopRunning()
        }
        session.outputs.compactMap {
            $0 as? AVCaptureAudioDataOutput
        }.forEach {
            $0.setSampleBufferDelegate(nil, queue: nil)
        }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        configuredDevice = nil
        removeNotifications()
        setEventHandler(nil)
    }

    private func registerNotifications(for device: AVCaptureDevice) {
        removeNotifications()
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let error = notification.userInfo?[
                    AVCaptureSessionErrorKey
                ] as? Error
                self?.enqueue(
                    .failure(
                        error
                            ?? MicrophoneCaptureError
                                .runtimeFailure
                    )
                )
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device,
                queue: nil
            ) { [weak self] _ in
                self?.enqueue(
                    .failure(
                        MicrophoneCaptureError
                            .deviceDisconnected
                    )
                )
            },
        ]
    }

    private func removeNotifications() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private func setEventHandler(
        _ handler:
            (@Sendable (AVCaptureMicrophoneSessionEvent) -> Void)?
    ) {
        handlerLock.lock()
        eventHandler = handler
        handlerLock.unlock()
    }

    private func send(_ event: AVCaptureMicrophoneSessionEvent) {
        handlerLock.lock()
        let handler = eventHandler
        handlerLock.unlock()
        handler?(event)
    }

    private func enqueue(_ event: AVCaptureMicrophoneSessionEvent) {
        sampleQueue.async { [self] in
            send(event)
        }
    }
}
