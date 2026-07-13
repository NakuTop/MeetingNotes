import AVFoundation
import Foundation

enum PCMConverterError: Error, Equatable, Sendable {
    case invalidInputFormat
    case unableToCreateOutputFormat
    case unableToCreateConverter
    case unableToCreateOutputBuffer
    case conversionFailed
    case missingOutputSamples
}

struct PCMConverter: Sendable {
    static let outputSampleRate: Double = 16_000

    func convert(
        _ input: AVAudioPCMBuffer,
        timestamp: TimeInterval
    ) throws -> CapturedAudioFrame {
        guard input.frameLength > 0,
              input.format.sampleRate > 0,
              input.format.channelCount > 0 else {
            throw PCMConverterError.invalidInputFormat
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PCMConverterError.unableToCreateOutputFormat
        }
        guard let converter = AVAudioConverter(
            from: input.format,
            to: outputFormat
        ) else {
            throw PCMConverterError.unableToCreateConverter
        }
        converter.primeMethod = .none

        let ratio = Self.outputSampleRate / input.format.sampleRate
        let expectedFrames = ceil(Double(input.frameLength) * ratio)
        let capacity = AVAudioFrameCount(max(1, expectedFrames))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw PCMConverterError.unableToCreateOutputBuffer
        }

        let inputProvider = ConverterInputProvider(input: input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard conversionError == nil, status != .error else {
            throw PCMConverterError.conversionFailed
        }
        guard output.frameLength > 0,
              let channel = output.floatChannelData?.pointee else {
            throw PCMConverterError.missingOutputSamples
        }

        let samples = UnsafeBufferPointer(
            start: channel,
            count: Int(output.frameLength)
        ).map { min(1, max(-1, $0)) }
        return CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: Self.outputSampleRate,
            channelCount: 1,
            samples: samples
        )
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var suppliedInput = false

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !suppliedInput else {
            status.pointee = .endOfStream
            return nil
        }
        suppliedInput = true
        status.pointee = .haveData
        return input
    }
}
