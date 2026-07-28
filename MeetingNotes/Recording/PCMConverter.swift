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

enum PCMAmplitudePolicy: Sendable {
    case speechLeveling
    case preserveAmplitude
}

final class PCMConverter:
    MeetingTrackPCMStreamingConverting,
    @unchecked Sendable {
    static let defaultOutputSampleRate: Double = 16_000
    static let playbackSampleRate: Double = 48_000
    private static let targetSpeechRMS = pow(10.0, -24.0 / 20.0)
    private static let maximumSpeechGain = 10.0
    private static let maximumPeak = 0.95
    private static let silenceFloor = 0.000_01

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormatSignature: InputFormatSignature?
    private var segmentStreamingState: SegmentStreamingConversionState?
    private let outputSampleRate: Double
    private let amplitudePolicy: PCMAmplitudePolicy

    init(
        outputSampleRate: Double = PCMConverter.defaultOutputSampleRate,
        amplitudePolicy: PCMAmplitudePolicy = .speechLeveling
    ) {
        self.outputSampleRate = outputSampleRate
        self.amplitudePolicy = amplitudePolicy
    }

    func reset() {
        lock.withLock {
            converter = nil
            inputFormatSignature = nil
            segmentStreamingState = nil
        }
    }

    func begin(inputSampleRate: Double) throws {
        try lock.withLock {
            guard inputSampleRate.isFinite,
                  inputSampleRate > 0,
                  let inputFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: inputSampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let outputFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: outputSampleRate,
                      channels: 1,
                      interleaved: false
                  ) else {
                throw PCMConverterError.invalidInputFormat
            }
            guard let converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ) else {
                throw PCMConverterError.unableToCreateConverter
            }
            converter.primeMethod = .pre
            segmentStreamingState = SegmentStreamingConversionState(
                converter: converter,
                inputFormat: inputFormat,
                outputFormat: outputFormat
            )
        }
    }

    func append(samples: [Float]) throws {
        try lock.withLock {
            guard let segmentStreamingState else {
                throw PCMConverterError.invalidInputFormat
            }
            try segmentStreamingState.append(samples: samples)
        }
    }

    func finishInput() {
        lock.withLock {
            segmentStreamingState?.finishInput()
        }
    }

    func pull(maximumOutputSampleCount: Int) throws
        -> MeetingPCMConversionPull {
        try lock.withLock {
            guard maximumOutputSampleCount > 0,
                  let outputFrameCapacity = AVAudioFrameCount(
                      exactly: maximumOutputSampleCount
                  ),
                  let state = segmentStreamingState else {
                throw PCMConverterError.unableToCreateOutputBuffer
            }
            if !state.inputProvider.hasQueuedInput,
               !state.inputProvider.isFinished {
                return MeetingPCMConversionPull(
                    samples: [],
                    inputFramesConsumed: 0,
                    needsInput: true,
                    isEndOfStream: false
                )
            }
            guard
                  let output = AVAudioPCMBuffer(
                      pcmFormat: state.outputFormat,
                      frameCapacity: outputFrameCapacity
                  ) else {
                throw PCMConverterError.unableToCreateOutputBuffer
            }

            let consumedBefore = state.inputProvider.consumedFrameCount
            var conversionError: NSError?
            let status = state.converter.convert(
                to: output,
                error: &conversionError
            ) { requestedPacketCount, inputStatus in
                state.inputProvider.next(
                    requestedPacketCount: requestedPacketCount,
                    status: inputStatus
                )
            }
            guard conversionError == nil,
                  status != .error,
                  !state.inputProvider.copyFailed else {
                throw PCMConverterError.conversionFailed
            }
            let consumed = state.inputProvider.consumedFrameCount
                - consumedBefore
            let samples: [Float]
            if output.frameLength > 0,
               let channel = output.floatChannelData?.pointee {
                let rawSamples = UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                ).map { $0.isFinite ? Double($0) : 0 }
                switch amplitudePolicy {
                case .speechLeveling:
                    samples = Self.levelSpeech(rawSamples)
                case .preserveAmplitude:
                    samples = rawSamples.map {
                        Float(min(1, max(-1, $0)))
                    }
                }
            } else {
                samples = []
            }
            return MeetingPCMConversionPull(
                samples: samples,
                inputFramesConsumed: consumed,
                needsInput:
                    status == .inputRanDry
                    && !state.inputProvider.isFinished,
                isEndOfStream: status == .endOfStream
            )
        }
    }

    func convert(_ frame: CapturedAudioFrame) throws -> CapturedAudioFrame {
        guard frame.channelCount == 1,
              frame.sampleRate.isFinite,
              frame.sampleRate > 0,
              !frame.samples.isEmpty,
              let frameCount = AVAudioFrameCount(exactly: frame.samples.count),
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: frame.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let input = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  frameCapacity: frameCount
              ),
              let channel = input.floatChannelData?.pointee else {
            throw PCMConverterError.invalidInputFormat
        }

        input.frameLength = frameCount
        _ = frame.samples.withUnsafeBytes { samples in
            memcpy(channel, samples.baseAddress, samples.count)
        }
        return try convert(input, timestamp: frame.timestamp)
    }

    func convert(
        _ input: AVAudioPCMBuffer,
        timestamp: TimeInterval
    ) throws -> CapturedAudioFrame {
        try lock.withLock {
            try convertLocked(input, timestamp: timestamp)
        }
    }

    static func outputFrameCapacity(
        inputFrameCount: AVAudioFrameCount,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) throws -> AVAudioFrameCount {
        let ratio = outputSampleRate / inputSampleRate
        let expectedFrames = ceil(Double(inputFrameCount) * ratio)
        guard expectedFrames.isFinite else {
            throw PCMConverterError.unableToCreateOutputBuffer
        }

        let paddedCapacity = max(1, expectedFrames + 16)
        guard paddedCapacity.isFinite,
              let capacity = AVAudioFrameCount(exactly: paddedCapacity) else {
            throw PCMConverterError.unableToCreateOutputBuffer
        }
        return capacity
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
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PCMConverterError.unableToCreateOutputFormat
        }
        let capacity = try Self.outputFrameCapacity(
            inputFrameCount: input.frameLength,
            inputSampleRate: input.format.sampleRate,
            outputSampleRate: outputSampleRate
        )
        let converter = try streamingConverter(
            for: input.format,
            outputFormat: outputFormat
        )
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
        let samples: [Float]
        switch amplitudePolicy {
        case .speechLeveling:
            samples = Self.levelSpeech(rawSamples)
        case .preserveAmplitude:
            samples = rawSamples.map { Float(min(1, max(-1, $0))) }
        }
        return CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: outputSampleRate,
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

private final class SegmentStreamingConversionState:
    @unchecked Sendable {
    let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let inputProvider = SegmentStreamingInputProvider()
    private var didAppendSourceInput = false
    private var didFinishInput = false
    private var lastSourceSample: Float?

    init(
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func append(samples: [Float]) throws {
        if !didAppendSourceInput,
           let firstSample = samples.first {
            let leadingFrames = Int(
                converter.primeInfo.leadingFrames
            )
            if leadingFrames > 0 {
                try inputProvider.append(
                    samples: Array(
                        repeating: firstSample,
                        count: leadingFrames
                    ),
                    format: inputFormat
                )
            }
        }
        didAppendSourceInput = true
        lastSourceSample = samples.last
        try inputProvider.append(
            samples: samples,
            format: inputFormat
        )
    }

    func finishInput() {
        guard !didFinishInput else {
            return
        }
        didFinishInput = true
        if let lastSourceSample {
            let trailingFrames = Int(
                converter.primeInfo.trailingFrames
            )
            if trailingFrames > 0 {
                do {
                    try inputProvider.append(
                        samples: Array(
                            repeating: lastSourceSample,
                            count: trailingFrames
                        ),
                        format: inputFormat
                    )
                } catch {
                    inputProvider.markCopyFailed()
                }
            }
        }
        inputProvider.finish()
    }
}

private final class SegmentStreamingInputProvider:
    @unchecked Sendable {
    private let lock = NSLock()
    private var queuedBuffers: [AVAudioPCMBuffer] = []
    private var nextFrame: AVAudioFramePosition = 0
    private var retainedSlice: AVAudioPCMBuffer?
    private var finished = false
    private var consumedFrames = 0
    private(set) var copyFailed = false

    var consumedFrameCount: Int {
        lock.withLock { consumedFrames }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    var hasQueuedInput: Bool {
        lock.withLock { !queuedBuffers.isEmpty }
    }

    func append(samples: [Float], format: AVAudioFormat) throws {
        guard !samples.isEmpty,
              let frameCount = AVAudioFrameCount(
                  exactly: samples.count
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: frameCount
              ),
              let channel = buffer.floatChannelData?.pointee else {
            throw PCMConverterError.invalidInputFormat
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            memcpy(
                channel,
                baseAddress,
                samples.count * MemoryLayout<Float>.size
            )
        }
        lock.withLock {
            queuedBuffers.append(buffer)
        }
    }

    func finish() {
        lock.withLock {
            finished = true
        }
    }

    func markCopyFailed() {
        lock.withLock {
            copyFailed = true
        }
    }

    func next(
        requestedPacketCount: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard let input = queuedBuffers.first else {
            status.pointee = finished ? .endOfStream : .noDataNow
            return nil
        }
        let remaining = AVAudioFramePosition(input.frameLength) - nextFrame
        guard remaining > 0 else {
            copyFailed = true
            status.pointee = .noDataNow
            return nil
        }

        let requestedFrames = max(
            1,
            AVAudioFramePosition(requestedPacketCount)
        )
        let frameCount = AVAudioFrameCount(
            min(remaining, requestedFrames)
        )
        let result: AVAudioPCMBuffer
        if nextFrame == 0, frameCount == input.frameLength {
            result = input
        } else {
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
            let sourceOffset = Int(nextFrame)
            let byteCount = Int(frameCount)
                * MemoryLayout<Float>.size
            memcpy(
                destinationChannels[0],
                sourceChannels[0].advanced(by: sourceOffset),
                byteCount
            )
            retainedSlice = slice
            result = slice
        }
        nextFrame += AVAudioFramePosition(frameCount)
        consumedFrames += Int(frameCount)
        if nextFrame == AVAudioFramePosition(input.frameLength) {
            queuedBuffers.removeFirst()
            nextFrame = 0
        }
        status.pointee = .haveData
        return result
    }
}
