import AVFoundation
import Foundation

struct MeetingAudioSampleChunk: Equatable, Sendable {
    let samples: [Float]
    let startingAt: TimeInterval
}

enum MeetingTrackAudioReaderError: Error, Equatable, Sendable {
    case multipleIterators
    case segmentIdentityChanged(index: Int)
    case unableToOpenSegment(index: Int)
    case reopenedSegmentFormatMismatch(index: Int)
    case reopenedSegmentFrameCountMismatch(
        index: Int,
        expected: Int64,
        actual: Int64
    )
    case shortRead(index: Int, expected: Int, actual: Int)
    case conversionStalled(index: Int)
}

struct MeetingAudioSampleChunks: AsyncSequence, Sendable {
    typealias Element = MeetingAudioSampleChunk

    struct AsyncIterator: AsyncIteratorProtocol {
        private let isAuthorized: Bool
        private let nextElement:
            @Sendable () async throws -> MeetingAudioSampleChunk?

        fileprivate init(
            isAuthorized: Bool,
            nextElement: @escaping @Sendable () async throws
                -> MeetingAudioSampleChunk?
        ) {
            self.isAuthorized = isAuthorized
            self.nextElement = nextElement
        }

        mutating func next() async throws -> MeetingAudioSampleChunk? {
            guard isAuthorized else {
                throw MeetingTrackAudioReaderError.multipleIterators
            }
            return try await nextElement()
        }
    }

    private let iterationLease = MeetingAudioSampleChunkIterationLease()
    private let nextElement:
        @Sendable () async throws -> MeetingAudioSampleChunk?

    init(_ chunks: [MeetingAudioSampleChunk]) {
        let state = MeetingAudioSampleChunkArrayState(chunks: chunks)
        nextElement = {
            await state.next()
        }
    }

    fileprivate init(
        nextElement: @escaping @Sendable () async throws
            -> MeetingAudioSampleChunk?
    ) {
        self.nextElement = nextElement
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            isAuthorized: iterationLease.claim(),
            nextElement: nextElement
        )
    }
}

protocol MeetingTrackAudioReading: Sendable {
    func chunks(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSampleChunks
}

struct MeetingTrackAudioSegmentFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let isFloat32: Bool
}

protocol MeetingTrackAudioSegmentReading: AnyObject, Sendable {
    var format: MeetingTrackAudioSegmentFormat { get }
    var declaredFrameCount: Int64 { get }

    func read(maximumFrameCount: Int) throws -> [Float]
    func close()
}

protocol MeetingTrackAudioSegmentReaderFactory: Sendable {
    func open(url: URL) throws -> any MeetingTrackAudioSegmentReading
}

struct MeetingPCMConversionPull: Equatable, Sendable {
    let samples: [Float]
    let inputFramesConsumed: Int
    let needsInput: Bool
    let isEndOfStream: Bool
}

protocol MeetingTrackPCMStreamingConverting: AnyObject, Sendable {
    func begin(inputSampleRate: Double) throws
    func append(samples: [Float]) throws
    func finishInput()
    func pull(maximumOutputSampleCount: Int) throws
        -> MeetingPCMConversionPull
    func reset()
}

actor MeetingTrackAudioReader: MeetingTrackAudioReading {
    static let productionMaximumChunkSampleCount =
        10 * Int(AudioSegmentManifest.transcriptionSampleRate)

    private let sourceLoader: MeetingAudioSourceLoader
    private let maximumChunkSampleCount: Int
    private let segmentReaderFactory:
        any MeetingTrackAudioSegmentReaderFactory
    private let makeConverter:
        @Sendable () -> any MeetingTrackPCMStreamingConverting

    init(
        sourceLoader: MeetingAudioSourceLoader,
        maximumChunkSampleCount: Int =
            productionMaximumChunkSampleCount,
        segmentReaderFactory:
            any MeetingTrackAudioSegmentReaderFactory =
                AVMeetingTrackAudioSegmentReaderFactory(),
        converter: (any MeetingTrackPCMStreamingConverting)? = nil
    ) {
        self.sourceLoader = sourceLoader
        self.maximumChunkSampleCount = max(1, maximumChunkSampleCount)
        self.segmentReaderFactory = segmentReaderFactory
        if let converter {
            makeConverter = { converter }
        } else {
            makeConverter = {
                PCMConverter(
                    outputSampleRate:
                        AudioSegmentManifest.transcriptionSampleRate,
                    amplitudePolicy: .preserveAmplitude
                )
            }
        }
    }

    func chunks(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSampleChunks {
        let source = try await sourceLoader.load(
            meetingID: meetingID,
            track: track
        )
        let state = MeetingTrackAudioReadState(
            source: source,
            sourceLoader: sourceLoader,
            maximumChunkSampleCount: maximumChunkSampleCount,
            segmentReaderFactory: segmentReaderFactory,
            converter: makeConverter()
        )
        return MeetingAudioSampleChunks {
            do {
                try Task.checkCancellation()
                return try await state.next()
            } catch is CancellationError {
                await state.close()
                throw CancellationError()
            }
        }
    }
}

private final class MeetingAudioSampleChunkIterationLease:
    @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else {
                return false
            }
            isClaimed = true
            return true
        }
    }
}

private actor MeetingAudioSampleChunkArrayState {
    private let chunks: [MeetingAudioSampleChunk]
    private var index = 0

    init(chunks: [MeetingAudioSampleChunk]) {
        self.chunks = chunks
    }

    func next() -> MeetingAudioSampleChunk? {
        guard index < chunks.count else {
            return nil
        }
        defer { index += 1 }
        return chunks[index]
    }
}

private final class AVMeetingTrackAudioSegmentReaderFactory:
    MeetingTrackAudioSegmentReaderFactory,
    @unchecked Sendable {
    func open(url: URL) throws -> any MeetingTrackAudioSegmentReading {
        try AVMeetingTrackAudioSegmentReader(url: url)
    }
}

private final class AVMeetingTrackAudioSegmentReader:
    MeetingTrackAudioSegmentReading,
    @unchecked Sendable {
    let format: MeetingTrackAudioSegmentFormat
    let declaredFrameCount: Int64

    private let audioFile: AVAudioFile

    init(url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        self.audioFile = audioFile
        let processingFormat = audioFile.processingFormat
        format = MeetingTrackAudioSegmentFormat(
            sampleRate: processingFormat.sampleRate,
            channelCount: Int(processingFormat.channelCount),
            isFloat32:
                processingFormat.commonFormat == .pcmFormatFloat32
        )
        declaredFrameCount = Int64(audioFile.length)
    }

    func read(maximumFrameCount: Int) throws -> [Float] {
        guard maximumFrameCount > 0,
              let frameCapacity = AVAudioFrameCount(
                  exactly: maximumFrameCount
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: audioFile.processingFormat,
                  frameCapacity: frameCapacity
              ) else {
            throw PCMConverterError.unableToCreateOutputBuffer
        }
        try audioFile.read(
            into: buffer,
            frameCount: frameCapacity
        )
        guard let channel = buffer.floatChannelData?.pointee else {
            throw PCMConverterError.invalidInputFormat
        }
        return Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            )
        )
    }

    func close() {
        audioFile.close()
    }
}

private actor MeetingTrackAudioReadState {
    private let source: MeetingAudioSource
    private let sourceLoader: MeetingAudioSourceLoader
    private let maximumChunkSampleCount: Int
    private let segmentReaderFactory:
        any MeetingTrackAudioSegmentReaderFactory
    private let converter: any MeetingTrackPCMStreamingConverting

    private var segmentIndex = 0
    private var segmentReader: (any MeetingTrackAudioSegmentReading)?
    private var decodedFramesInSegment: Int64 = 0
    private var didFinishInput = false
    private var didReachEndOfStream = false
    private var consecutiveStalledPulls = 0
    private var outputFramesInSegment = 0
    private var pendingSamples: [Float] = []
    private var pendingStartingAt: TimeInterval = 0
    private var nextOutputTime: TimeInterval = 0

    init(
        source: MeetingAudioSource,
        sourceLoader: MeetingAudioSourceLoader,
        maximumChunkSampleCount: Int,
        segmentReaderFactory:
            any MeetingTrackAudioSegmentReaderFactory,
        converter: any MeetingTrackPCMStreamingConverting
    ) {
        self.source = source
        self.sourceLoader = sourceLoader
        self.maximumChunkSampleCount = maximumChunkSampleCount
        self.segmentReaderFactory = segmentReaderFactory
        self.converter = converter
    }

    func next() async throws -> MeetingAudioSampleChunk? {
        do {
            while true {
                try Task.checkCancellation()
                if !pendingSamples.isEmpty {
                    return takePendingChunk()
                }
                guard try await prepareConvertedSamples() else {
                    return nil
                }
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        closeCurrentSegment()
    }

    private func takePendingChunk() -> MeetingAudioSampleChunk {
        let count = min(maximumChunkSampleCount, pendingSamples.count)
        let samples = Array(pendingSamples.prefix(count))
        pendingSamples.removeFirst(count)
        let startingAt = pendingStartingAt
        pendingStartingAt += Double(count)
            / AudioSegmentManifest.transcriptionSampleRate
        nextOutputTime = pendingStartingAt
        return MeetingAudioSampleChunk(
            samples: samples,
            startingAt: startingAt
        )
    }

    private func prepareConvertedSamples() async throws -> Bool {
        while true {
            try Task.checkCancellation()
            if segmentReader == nil {
                guard segmentIndex < source.segmentURLs.count else {
                    return false
                }
                try await openCurrentSegment()
            }
            if didReachEndOfStream {
                advanceToNextSegment()
                continue
            }

            let pull = try converter.pull(
                maximumOutputSampleCount: maximumChunkSampleCount
            )
            let madeConversionProgress =
                pull.inputFramesConsumed > 0
                || !pull.samples.isEmpty
                || pull.isEndOfStream
            if madeConversionProgress {
                consecutiveStalledPulls = 0
            }

            if pull.isEndOfStream {
                didReachEndOfStream = true
            }
            if !pull.samples.isEmpty {
                let remainingOutputFrames = max(
                    0,
                    expectedOutputFrameCount()
                        - outputFramesInSegment
                )
                let acceptedSamples = Array(
                    pull.samples.prefix(remainingOutputFrames)
                )
                outputFramesInSegment += acceptedSamples.count
                if !acceptedSamples.isEmpty {
                    pendingSamples = acceptedSamples
                    pendingStartingAt = nextOutputTime
                    return true
                }
            }
            if pull.isEndOfStream {
                advanceToNextSegment()
                continue
            }
            if pull.needsInput {
                try supplyInputOrFinish()
                consecutiveStalledPulls = 0
                continue
            }
            if madeConversionProgress {
                continue
            }

            consecutiveStalledPulls += 1
            if consecutiveStalledPulls >= 2 {
                throw MeetingTrackAudioReaderError.conversionStalled(
                    index: segmentIndex
                )
            }
        }
    }

    private func openCurrentSegment() async throws {
        do {
            try await sourceLoader.confirmSegmentIdentity(
                in: source,
                segmentIndex: segmentIndex
            )
        } catch {
            throw MeetingTrackAudioReaderError.segmentIdentityChanged(
                index: segmentIndex
            )
        }

        let reader: any MeetingTrackAudioSegmentReading
        do {
            reader = try segmentReaderFactory.open(
                url: source.segmentURLs[segmentIndex]
            )
        } catch {
            throw MeetingTrackAudioReaderError.unableToOpenSegment(
                index: segmentIndex
            )
        }
        do {
            try await sourceLoader.confirmSegmentIdentity(
                in: source,
                segmentIndex: segmentIndex
            )
        } catch {
            reader.close()
            throw MeetingTrackAudioReaderError.segmentIdentityChanged(
                index: segmentIndex
            )
        }

        guard source.sampleRate == PCMConverter.playbackSampleRate,
              reader.format.sampleRate == PCMConverter.playbackSampleRate,
              reader.format.channelCount == source.channelCount,
              reader.format.isFloat32 else {
            reader.close()
            throw MeetingTrackAudioReaderError
                .reopenedSegmentFormatMismatch(index: segmentIndex)
        }
        let expectedFrameCount = source.segmentFrameCounts[segmentIndex]
        guard reader.declaredFrameCount == expectedFrameCount else {
            reader.close()
            throw MeetingTrackAudioReaderError
                .reopenedSegmentFrameCountMismatch(
                    index: segmentIndex,
                    expected: expectedFrameCount,
                    actual: reader.declaredFrameCount
                )
        }

        do {
            try converter.begin(inputSampleRate: reader.format.sampleRate)
        } catch {
            reader.close()
            converter.reset()
            throw error
        }
        segmentReader = reader
        decodedFramesInSegment = 0
        didFinishInput = false
        didReachEndOfStream = false
        consecutiveStalledPulls = 0
        outputFramesInSegment = 0
        nextOutputTime = source.segmentStartTimes[segmentIndex]
    }

    private func supplyInputOrFinish() throws {
        let expectedFrameCount = source.segmentFrameCounts[segmentIndex]
        let remainingFrames =
            expectedFrameCount - decodedFramesInSegment
        if remainingFrames > 0 {
            guard let segmentReader else {
                throw MeetingTrackAudioReaderError
                    .unableToOpenSegment(index: segmentIndex)
            }
            let requestedFrameCount = min(
                maximumInputFrameCount(
                    for: segmentReader.format.sampleRate
                ),
                Int(remainingFrames)
            )
            let samples = try segmentReader.read(
                maximumFrameCount: requestedFrameCount
            )
            guard samples.count == requestedFrameCount else {
                throw MeetingTrackAudioReaderError.shortRead(
                    index: segmentIndex,
                    expected: requestedFrameCount,
                    actual: samples.count
                )
            }
            decodedFramesInSegment += Int64(samples.count)
            try converter.append(samples: samples)
        } else if !didFinishInput {
            converter.finishInput()
            didFinishInput = true
        }
    }

    private func maximumInputFrameCount(
        for inputSampleRate: Double
    ) -> Int {
        let scaled = ceil(
            Double(
                MeetingTrackAudioReader
                    .productionMaximumChunkSampleCount
            )
                * inputSampleRate
                / AudioSegmentManifest.transcriptionSampleRate
        )
        guard scaled.isFinite,
              scaled >= 1,
              scaled <= Double(Int.max) else {
            return 1
        }
        return Int(scaled)
    }

    private func expectedOutputFrameCount() -> Int {
        let scaled = round(
            Double(source.segmentFrameCounts[segmentIndex])
                * AudioSegmentManifest.transcriptionSampleRate
                / source.sampleRate
        )
        guard scaled.isFinite,
              scaled >= 0,
              scaled <= Double(Int.max) else {
            return 0
        }
        return Int(scaled)
    }

    private func advanceToNextSegment() {
        closeCurrentSegment()
        segmentIndex += 1
    }

    private func closeCurrentSegment() {
        segmentReader?.close()
        segmentReader = nil
        converter.reset()
        decodedFramesInSegment = 0
        didFinishInput = false
        didReachEndOfStream = false
        consecutiveStalledPulls = 0
        outputFramesInSegment = 0
        pendingSamples.removeAll(keepingCapacity: false)
    }
}
