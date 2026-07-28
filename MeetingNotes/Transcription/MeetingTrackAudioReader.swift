import AVFoundation
import Foundation

struct MeetingAudioSampleChunk: Equatable, Sendable {
    let samples: [Float]
    let startingAt: TimeInterval
}

struct MeetingAudioSampleChunks: AsyncSequence, Sendable {
    typealias Element = MeetingAudioSampleChunk

    struct AsyncIterator: AsyncIteratorProtocol {
        private let nextElement:
            @Sendable () async throws -> MeetingAudioSampleChunk?

        fileprivate init(
            nextElement: @escaping @Sendable () async throws
                -> MeetingAudioSampleChunk?
        ) {
            self.nextElement = nextElement
        }

        mutating func next() async throws -> MeetingAudioSampleChunk? {
            try await nextElement()
        }
    }

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
        AsyncIterator(nextElement: nextElement)
    }
}

protocol MeetingTrackAudioReading: Sendable {
    func chunks(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSampleChunks
}

actor MeetingTrackAudioReader: MeetingTrackAudioReading {
    static let productionMaximumChunkSampleCount =
        10 * Int(AudioSegmentManifest.transcriptionSampleRate)

    private let sourceLoader: MeetingAudioSourceLoader
    private let maximumChunkSampleCount: Int

    init(
        sourceLoader: MeetingAudioSourceLoader,
        maximumChunkSampleCount: Int =
            productionMaximumChunkSampleCount
    ) {
        self.sourceLoader = sourceLoader
        self.maximumChunkSampleCount = max(1, maximumChunkSampleCount)
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
            maximumChunkSampleCount: maximumChunkSampleCount
        )
        return MeetingAudioSampleChunks {
            try await state.next()
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

private actor MeetingTrackAudioReadState {
    private let source: MeetingAudioSource
    private let maximumChunkSampleCount: Int
    private let converter = PCMConverter(
        outputSampleRate: AudioSegmentManifest.transcriptionSampleRate,
        amplitudePolicy: .preserveAmplitude
    )

    private var segmentIndex = 0
    private var audioFile: AVAudioFile?
    private var decodedFramesInSegment: Int64 = 0
    private var pendingSamples: [Float] = []
    private var pendingStartingAt: TimeInterval = 0
    private var nextOutputTime: TimeInterval = 0

    init(
        source: MeetingAudioSource,
        maximumChunkSampleCount: Int
    ) {
        self.source = source
        self.maximumChunkSampleCount = maximumChunkSampleCount
    }

    func next() throws -> MeetingAudioSampleChunk? {
        while true {
            if !pendingSamples.isEmpty {
                return takePendingChunk()
            }
            guard try prepareConvertedSamples() else {
                return nil
            }
        }
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

    private func prepareConvertedSamples() throws -> Bool {
        while true {
            if audioFile == nil {
                guard segmentIndex < source.segmentURLs.count else {
                    return false
                }
                audioFile = try AVAudioFile(
                    forReading: source.segmentURLs[segmentIndex]
                )
                decodedFramesInSegment = 0
                nextOutputTime = source.segmentStartTimes[segmentIndex]
            }
            guard let audioFile else {
                continue
            }

            let maximumInputFrames = try maximumInputFrameCount(
                for: audioFile.processingFormat.sampleRate
            )
            let remainingFrames = source.segmentFrameCounts[segmentIndex]
                - decodedFramesInSegment
            guard remainingFrames > 0 else {
                audioFile.close()
                self.audioFile = nil
                segmentIndex += 1
                continue
            }
            let inputFrameCount = AVAudioFrameCount(
                min(Int64(maximumInputFrames), remainingFrames)
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: inputFrameCount
            ) else {
                throw PCMConverterError.unableToCreateOutputBuffer
            }
            try audioFile.read(
                into: buffer,
                frameCount: inputFrameCount
            )
            guard buffer.frameLength > 0 else {
                audioFile.close()
                self.audioFile = nil
                segmentIndex += 1
                continue
            }
            decodedFramesInSegment += Int64(buffer.frameLength)

            let converted = try converter.convert(
                buffer,
                timestamp: nextOutputTime
            )
            pendingSamples = converted.samples
            pendingStartingAt = nextOutputTime
            return true
        }
    }

    private func maximumInputFrameCount(
        for inputSampleRate: Double
    ) throws -> AVAudioFrameCount {
        let scaled = ceil(
            Double(maximumChunkSampleCount)
                * inputSampleRate
                / AudioSegmentManifest.transcriptionSampleRate
        )
        guard scaled.isFinite,
              let count = AVAudioFrameCount(exactly: max(1, scaled)) else {
            throw PCMConverterError.unableToCreateOutputBuffer
        }
        return count
    }
}
