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

final class PCMConverter: @unchecked Sendable {
    static let outputSampleRate: Double = 16_000
    private static let targetSpeechRMS = pow(10.0, -24.0 / 20.0)
    private static let maximumSpeechGain = 10.0
    private static let maximumPeak = 0.95
    private static let silenceFloor = 0.000_01

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormatSignature: InputFormatSignature?

    func reset() {
        lock.withLock {
            converter = nil
            inputFormatSignature = nil
        }
    }

    func convert(
        _ input: AVAudioPCMBuffer,
        timestamp: TimeInterval
    ) throws -> CapturedAudioFrame {
        try lock.withLock {
            try convertLocked(input, timestamp: timestamp)
        }
    }

    private func convertLocked(
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
        let converter = try streamingConverter(
            for: input.format,
            outputFormat: outputFormat
        )

        let ratio = Self.outputSampleRate / input.format.sampleRate
        let expectedFrames = ceil(Double(input.frameLength) * ratio)
        let capacity = AVAudioFrameCount(max(1, expectedFrames + 16))
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
        ) { requestedPacketCount, inputStatus in
            inputProvider.next(
                requestedPacketCount: requestedPacketCount,
                status: inputStatus
            )
        }
        guard conversionError == nil,
              status != .error,
              !inputProvider.copyFailed else {
            throw PCMConverterError.conversionFailed
        }
        guard output.frameLength > 0,
              let channel = output.floatChannelData?.pointee else {
            throw PCMConverterError.missingOutputSamples
        }

        let rawSamples = UnsafeBufferPointer(
            start: channel,
            count: Int(output.frameLength)
        ).map { $0.isFinite ? Double($0) : 0 }
        let samples = Self.levelSpeech(rawSamples)
        return CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: Self.outputSampleRate,
            channelCount: 1,
            samples: samples
        )
    }

    private func streamingConverter(
        for inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioConverter {
        let signature = InputFormatSignature(inputFormat)
        if signature != inputFormatSignature {
            guard let newConverter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ) else {
                throw PCMConverterError.unableToCreateConverter
            }
            newConverter.primeMethod = .none
            converter = newConverter
            inputFormatSignature = signature
        }
        guard let converter else {
            throw PCMConverterError.unableToCreateConverter
        }
        return converter
    }

    private static func levelSpeech(_ rawSamples: [Double]) -> [Float] {
        guard !rawSamples.isEmpty else { return [] }
        let sumOfSquares = rawSamples.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Double(rawSamples.count))
        let peak = rawSamples.reduce(0) { max($0, abs($1)) }
        guard rms > silenceFloor, peak > 0 else {
            return Array(repeating: 0, count: rawSamples.count)
        }

        let speechGain = min(maximumSpeechGain, targetSpeechRMS / rms)
        let nonAttenuatingGain = max(1, speechGain)
        let peakSafeGain = min(nonAttenuatingGain, maximumPeak / peak)
        return rawSamples.map { sample in
            Float(min(maximumPeak, max(-maximumPeak, sample * peakSafeGain)))
        }
    }
}

private struct InputFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var nextFrame: AVAudioFramePosition = 0
    private var retainedSlice: AVAudioPCMBuffer?
    private(set) var copyFailed = false

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(
        requestedPacketCount: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let remaining = AVAudioFramePosition(input.frameLength) - nextFrame
        guard remaining > 0 else {
            status.pointee = .noDataNow
            return nil
        }

        let requestedFrames = max(1, AVAudioFramePosition(requestedPacketCount))
        let frameCount = AVAudioFrameCount(min(remaining, requestedFrames))
        if nextFrame == 0, frameCount == input.frameLength {
            nextFrame += AVAudioFramePosition(frameCount)
            status.pointee = .haveData
            return input
        }

        guard let sourceChannels = input.floatChannelData,
              let slice = AVAudioPCMBuffer(
                  pcmFormat: input.format,
                  frameCapacity: frameCount
              ),
              let destinationChannels = slice.floatChannelData else {
            copyFailed = true
            status.pointee = .noDataNow
            return nil
        }
        slice.frameLength = frameCount
        let channelBufferCount = input.format.isInterleaved
            ? 1
            : Int(input.format.channelCount)
        let samplesPerFrame = input.format.isInterleaved
            ? Int(input.format.channelCount)
            : 1
        let sourceOffset = Int(nextFrame) * samplesPerFrame
        let byteCount = Int(frameCount)
            * samplesPerFrame
            * MemoryLayout<Float>.size
        for channel in 0..<channelBufferCount {
            memcpy(
                destinationChannels[channel],
                sourceChannels[channel].advanced(by: sourceOffset),
                byteCount
            )
        }
        nextFrame += AVAudioFramePosition(frameCount)
        retainedSlice = slice
        status.pointee = .haveData
        return slice
    }
}
