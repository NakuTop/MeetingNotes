import AVFoundation
import Foundation

enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case backlogCapacityExceeded
}

actor MicrophoneCaptureSource: AudioCaptureSource {
    static let productionDrainCapacity = 256

    private let engine: AVAudioEngine
    private let storageConverter: PCMConverter
    private let transcriptionConverter: PCMConverter
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var isRunning = false
    private var isPaused = false
    private var firstSampleTime: AVAudioFramePosition?
    private var drainQueue: MicrophoneCaptureDrainQueue<MicrophoneCaptureEvent>?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        storageConverter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.playbackSampleRate,
            amplitudePolicy: .preserveAmplitude
        ),
        transcriptionConverter: PCMConverter = PCMConverter(outputSampleRate: PCMConverter.defaultOutputSampleRate)
    ) {
        self.engine = engine
        self.storageConverter = storageConverter
        self.transcriptionConverter = transcriptionConverter
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }
        storageConverter.reset()
        transcriptionConverter.reset()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        let streamPair = AsyncThrowingStream<CapturedAudioFrame, Error>.makeStream()
        continuation = streamPair.continuation
        isRunning = true
        isPaused = false
        firstSampleTime = nil

        let drainQueue = MicrophoneCaptureDrainQueue<MicrophoneCaptureEvent>(
            capacity: Self.productionDrainCapacity,
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

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { buffer, time in
            guard let box = Self.copyBuffer(buffer) else {
                drainQueue.enqueue(
                    .failure(AudioCaptureError.unableToCopyInputBuffer)
                )
                drainQueue.finishAccepting()
                return
            }
            drainQueue.enqueue(
                .buffer(
                    box,
                    sampleTime: time.sampleTime,
                    sampleRate: time.sampleRate
                )
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            await drainQueue.finishAndWait()
            self.drainQueue = nil
            isRunning = false
            storageConverter.reset()
            transcriptionConverter.reset()
            continuation?.finish(throwing: AudioCaptureError.engineStartFailed)
            continuation = nil
            throw AudioCaptureError.engineStartFailed
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
        engine.pause()
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
            try engine.start()
            isPaused = false
        } catch {
            throw AudioCaptureError.engineStartFailed
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
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        drainQueue?.finishAccepting()
        await drainQueue?.waitUntilDrained()
        drainQueue = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }

    private func consume(_ event: MicrophoneCaptureEvent) {
        switch event {
        case let .buffer(box, sampleTime, sampleRate):
            process(
                box,
                sampleTime: sampleTime,
                sampleRate: sampleRate
            )
        case let .failure(error):
            finishAfterFailure(error)
        }
    }

    private func handleBacklogOverflow() async {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        drainQueue?.finishAccepting()
        await drainQueue?.waitUntilDrained()
        guard isRunning else { return }
        drainQueue = nil
        continuation?.finish(
            throwing: MicrophoneCaptureError.backlogCapacityExceeded
        )
        continuation = nil
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }

    private func process(
        _ box: AudioBufferBox,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double
    ) {
        guard isRunning else {
            return
        }
        if firstSampleTime == nil {
            firstSampleTime = sampleTime
        }
        let origin = firstSampleTime ?? sampleTime
        let timestamp = sampleRate > 0
            ? max(0, Double(sampleTime - origin) / sampleRate)
            : 0

        do {
            let storageFrame = try storageConverter.convert(
                box.buffer,
                timestamp: timestamp
            )
            let transcriptionFrame = try transcriptionConverter.convert(
                box.buffer,
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
            continuation?.yield(frame)
        } catch {
            finishAfterFailure(error)
        }
    }

    private func finishAfterFailure(_ error: Error) {
        guard isRunning else {
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        drainQueue?.finishAccepting()
        continuation?.finish(throwing: error)
        continuation = nil
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        storageConverter.reset()
        transcriptionConverter.reset()
    }

    nonisolated private static func copyBuffer(
        _ source: AVAudioPCMBuffer
    ) -> AudioBufferBox? {
        guard let sourceChannels = source.floatChannelData,
              let copy = AVAudioPCMBuffer(
                  pcmFormat: source.format,
                  frameCapacity: source.frameLength
              ),
              let copyChannels = copy.floatChannelData else {
            return nil
        }
        copy.frameLength = source.frameLength
        let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(source.format.channelCount) {
            memcpy(copyChannels[channel], sourceChannels[channel], byteCount)
        }
        return AudioBufferBox(copy)
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
    case buffer(
        AudioBufferBox,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double
    )
    case failure(AudioCaptureError)
}

private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
