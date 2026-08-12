import AVFoundation
import Foundation

enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case backlogCapacityExceeded
    case selectedDeviceUnavailable
    case defaultDeviceUnavailable
    case unableToConfigureDevice
    case unableToStartSession
    case deviceDisconnected
    case runtimeFailure
    case permissionNotDetermined
    case permissionDenied
    case permissionRestricted
    case noUsableInputDevice
    case captureNoFrames
}

actor MicrophoneCaptureSource: AudioCaptureSource {
    static let productionDrainCapacity = 256

    private let selectedDeviceID: String?
    private let sampleProvider: any MicrophoneSampleProviding
    private let storageConverter: PCMConverter
    private let transcriptionConverter: PCMConverter
    private let drainCapacity: Int
    private let beforeProcessingSample: @Sendable () async -> Void
    private var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation?
    private var isRunning = false
    private var isPaused = false
    private var firstSampleTime: AVAudioFramePosition?
    private var drainQueue: MicrophoneCaptureDrainQueue<MicrophoneCaptureEvent>?
    private var sampleConsumptionTask: Task<Void, Never>?

    init(
        selectedDeviceID: String? = nil,
        sampleProvider: any MicrophoneSampleProviding =
            AVCaptureMicrophoneSampleProvider(),
        storageConverter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.playbackSampleRate,
            amplitudePolicy: .preserveAmplitude
        ),
        transcriptionConverter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.defaultOutputSampleRate
        ),
        drainCapacity: Int =
            MicrophoneCaptureSource.productionDrainCapacity,
        beforeProcessingSample:
            @escaping @Sendable () async -> Void = {}
    ) {
        self.selectedDeviceID = selectedDeviceID
        self.sampleProvider = sampleProvider
        self.storageConverter = storageConverter
        self.transcriptionConverter = transcriptionConverter
        self.drainCapacity = max(1, drainCapacity)
        self.beforeProcessingSample = beforeProcessingSample
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }
        storageConverter.reset()
        transcriptionConverter.reset()
        let streamPair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream()
        let samples: AsyncThrowingStream<MicrophoneSample, Error>
        do {
            samples = try await sampleProvider.start(
                deviceID: selectedDeviceID
            )
        } catch {
            storageConverter.reset()
            transcriptionConverter.reset()
            streamPair.continuation.finish(throwing: error)
            throw error
        }

        continuation = streamPair.continuation
        isRunning = true
        isPaused = false
        firstSampleTime = nil

        let drainQueue = MicrophoneCaptureDrainQueue<MicrophoneCaptureEvent>(
            capacity: drainCapacity,
            onOverflow: { [weak self] in
                Task {
                    await self?.handleBacklogOverflow()
                }
            },
            handler: { [weak self] event in
                await self?.consume(event)
            }
        )
        self.drainQueue = drainQueue
        sampleConsumptionTask = Task {
            do {
                for try await sample in samples {
                    guard drainQueue.enqueue(.sample(sample)) else {
                        return
                    }
                }
                drainQueue.enqueue(.finished)
            } catch {
                drainQueue.enqueue(.failure(error))
            }
            drainQueue.finishAccepting()
        }
        return streamPair.stream
    }

    func pause() async throws {
        guard isRunning else {
            throw AudioCaptureError.notRunning
        }
        guard !isPaused else {
            return
        }
        try await sampleProvider.pause()
        isPaused = true
    }

    func resume() async throws {
        guard isRunning else {
            throw AudioCaptureError.notRunning
        }
        guard isPaused else {
            return
        }
        do {
            try await sampleProvider.resume()
            isPaused = false
        } catch {
            throw error
        }
    }

    func stop() async {
        guard isRunning else {
            drainQueue?.finishAccepting()
            await drainQueue?.waitUntilDrained()
            drainQueue = nil
            storageConverter.reset()
            transcriptionConverter.reset()
            return
        }
        drainQueue?.finishAccepting()
        await sampleProvider.stop()
        await sampleConsumptionTask?.value
        sampleConsumptionTask = nil
        await drainQueue?.waitUntilDrained()
        drainQueue = nil
        isRunning = false
        isPaused = false
        continuation?.finish()
        continuation = nil
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }

    private func consume(_ event: MicrophoneCaptureEvent) async {
        switch event {
        case let .sample(sample):
            await process(sample)
        case let .failure(error):
            await finishAfterFailure(error)
        case .finished:
            await finishAfterProviderCompletion()
        }
    }

    private func handleBacklogOverflow() async {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        let draining = drainQueue
        drainQueue = nil
        draining?.finishAccepting()
        await sampleProvider.stop()
        sampleConsumptionTask = nil
        continuation?.finish(
            throwing: MicrophoneCaptureError.backlogCapacityExceeded
        )
        continuation = nil
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
        if let draining {
            Task {
                await draining.waitUntilDrained()
            }
        }
    }

    private func process(_ sample: MicrophoneSample) async {
        guard isRunning else {
            return
        }
        await beforeProcessingSample()
        guard isRunning else {
            return
        }
        if firstSampleTime == nil {
            firstSampleTime = sample.sampleTime
        }
        let origin = firstSampleTime ?? sample.sampleTime
        let timestamp = sample.sampleRate > 0
            ? max(
                0,
                Double(sample.sampleTime - origin) / sample.sampleRate
            )
            : 0

        do {
            let storageFrame = try storageConverter.convert(
                sample.buffer,
                timestamp: timestamp
            )
            let transcriptionFrame = try transcriptionConverter.convert(
                sample.buffer,
                timestamp: timestamp
            )
            let frame = CapturedAudioFrame(
                timestamp: storageFrame.timestamp,
                sampleRate: storageFrame.sampleRate,
                channelCount: storageFrame.channelCount,
                samples: storageFrame.samples,
                transcriptionSamples: transcriptionFrame.samples,
                transcriptionSampleRate: transcriptionFrame.sampleRate
            )
            continuation?.yield(Self.packet(from: frame))
        } catch {
            await finishAfterFailure(error)
        }
    }

    nonisolated static func packet(
        from frame: CapturedAudioFrame
    ) -> CapturedAudioPacket {
        CapturedAudioPacket(master: frame, sourceFrames: [:])
    }

    private func finishAfterFailure(_ error: Error) async {
        guard isRunning else {
            return
        }
        isRunning = false
        isPaused = false
        drainQueue?.finishAccepting()
        await sampleProvider.stop()
        continuation?.finish(throwing: error)
        continuation = nil
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }

    private func finishAfterProviderCompletion() async {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        await sampleProvider.stop()
        continuation?.finish()
        continuation = nil
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }
}

final class MicrophoneCaptureDrainQueue<Element: Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable (Element) async -> Void
    typealias OverflowHandler = @Sendable () -> Void

    private let state: MicrophoneCaptureDrainState<Element>
    private let processingTask: Task<Void, Never>
    private let onOverflow: OverflowHandler

    init(
        capacity: Int,
        onOverflow: @escaping OverflowHandler = {},
        handler: @escaping Handler
    ) {
        let pair = AsyncStream<Element>.makeStream()
        let state = MicrophoneCaptureDrainState(
            capacity: capacity,
            continuation: pair.continuation
        )
        self.state = state
        self.onOverflow = onOverflow
        processingTask = Task {
            for await element in pair.stream {
                await handler(element)
                state.didProcessElement()
            }
        }
    }

    @discardableResult
    func enqueue(_ element: Element) -> Bool {
        switch state.enqueue(element) {
        case .accepted:
            return true
        case .overflowed:
            onOverflow()
            return false
        case .closed:
            return false
        }
    }

    func finishAccepting() {
        state.finishAccepting()
    }

    func waitUntilDrained() async {
        await processingTask.value
    }

    func finishAndWait() async {
        finishAccepting()
        await waitUntilDrained()
    }
}

private final class MicrophoneCaptureDrainState<Element: Sendable>:
    @unchecked Sendable {
    enum EnqueueResult {
        case accepted
        case overflowed
        case closed
    }

    private let lock = NSLock()
    private let capacity: Int
    private let continuation: AsyncStream<Element>.Continuation
    private var pendingCount = 0
    private var isAccepting = true

    init(
        capacity: Int,
        continuation: AsyncStream<Element>.Continuation
    ) {
        self.capacity = max(1, capacity)
        self.continuation = continuation
    }

    func enqueue(_ element: Element) -> EnqueueResult {
        lock.lock()
        defer { lock.unlock() }
        guard isAccepting else { return .closed }
        guard pendingCount < capacity else {
            isAccepting = false
            continuation.finish()
            return .overflowed
        }
        pendingCount += 1
        continuation.yield(element)
        return .accepted
    }

    func didProcessElement() {
        lock.lock()
        pendingCount = max(0, pendingCount - 1)
        lock.unlock()
    }

    func finishAccepting() {
        lock.lock()
        guard isAccepting else {
            lock.unlock()
            return
        }
        isAccepting = false
        continuation.finish()
        lock.unlock()
    }
}

private enum MicrophoneCaptureEvent: @unchecked Sendable {
    case sample(MicrophoneSample)
    case failure(Error)
    case finished
}
