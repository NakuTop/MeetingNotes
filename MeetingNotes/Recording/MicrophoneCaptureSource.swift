import AVFoundation
import Foundation

actor MicrophoneCaptureSource: AudioCaptureSource {
    private let engine: AVAudioEngine
    private let converter: PCMConverter
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var isRunning = false
    private var isPaused = false
    private var firstSampleTime: AVAudioFramePosition?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        converter: PCMConverter = PCMConverter()
    ) {
        self.engine = engine
        self.converter = converter
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }
        converter.reset()
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

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self] buffer, time in
            guard let source = self else {
                return
            }
            guard let box = Self.copyBuffer(buffer) else {
                Task {
                    await source.finishAfterFailure(
                        AudioCaptureError.unableToCopyInputBuffer
                    )
                }
                return
            }
            let sampleTime = time.sampleTime
            let sampleRate = time.sampleRate
            Task {
                await source.process(
                    box,
                    sampleTime: sampleTime,
                    sampleRate: sampleRate
                )
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            isRunning = false
            converter.reset()
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
            converter.reset()
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation?.finish()
        continuation = nil
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        converter.reset()
    }

    private func process(
        _ box: AudioBufferBox,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double
    ) {
        guard isRunning, !isPaused else {
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
            let frame = try converter.convert(box.buffer, timestamp: timestamp)
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
        continuation?.finish(throwing: error)
        continuation = nil
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        converter.reset()
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

private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
