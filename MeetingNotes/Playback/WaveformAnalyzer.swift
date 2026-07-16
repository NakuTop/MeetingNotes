import AVFoundation
import Foundation

struct WaveformSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let manifestSignature: String
    let sourceIdentitySignature: String
    let values: [Float]
}

enum WaveformAnalyzerError: Error, Equatable, Sendable {
    case invalidBucketCount(Int)
    case invalidAudioSource
    case unreadableSegment(index: Int)
    case incompleteSegment(index: Int)
    case unsupportedAudioBuffer(index: Int)
    case segmentIdentityChanged(index: Int)
}

actor WaveformAnalyzer {
    typealias AudioFileOpener = @Sendable (URL) throws -> AVAudioFile
    typealias BeforeReadingChunk = @Sendable (AVAudioFrameCount) throws -> Void
    typealias CacheWriter = @Sendable (WaveformSnapshot, UUID) async throws -> Void

    private struct AnalysisKey: Hashable, Sendable {
        let meetingID: UUID
        let manifestSignature: String
        let sourceIdentitySignature: String
        let bucketCount: Int
    }

    private struct InFlightAnalysis {
        let task: Task<[Float], Error>
        var waiters: Set<UUID>
    }

    private static let maximumFramesPerRead: AVAudioFrameCount = 4_096

    /// Caps automatic waveform gain at 50 dB so inaudible numerical noise is
    /// preserved as a tiny value instead of being expanded to full scale.
    static let minimumNormalizationDecibelsFullScale = -50.0
    static let minimumNormalizationRMS = pow(
        10,
        minimumNormalizationDecibelsFullScale / 20
    )

    private let fileStore: MeetingFileStore
    private let openAudioFile: AudioFileOpener
    private let beforeReadingChunk: BeforeReadingChunk
    private let cacheWriter: CacheWriter
    private var inFlight: [AnalysisKey: InFlightAnalysis] = [:]

    init(
        fileStore: MeetingFileStore,
        openAudioFile: @escaping AudioFileOpener = { url in
            try AVAudioFile(forReading: url)
        },
        beforeReadingChunk: @escaping BeforeReadingChunk = { _ in },
        cacheWriter: CacheWriter? = nil
    ) {
        self.fileStore = fileStore
        self.openAudioFile = openAudioFile
        self.beforeReadingChunk = beforeReadingChunk
        self.cacheWriter = cacheWriter ?? { snapshot, meetingID in
            try await fileStore.saveWaveformSnapshot(
                snapshot,
                meetingID: meetingID
            )
        }
    }

    func values(
        for source: MeetingAudioSource,
        bucketCount: Int
    ) async throws -> [Float] {
        guard bucketCount > 0 else {
            throw WaveformAnalyzerError.invalidBucketCount(bucketCount)
        }
        let key = AnalysisKey(
            meetingID: source.meetingID,
            manifestSignature: source.manifestSignature,
            sourceIdentitySignature: source.identitySignature,
            bucketCount: bucketCount
        )
        let waiterID = UUID()
        let analysis: Task<[Float], Error>
        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            analysis = existing.task
        } else {
            let fileStore = fileStore
            let openAudioFile = openAudioFile
            let beforeReadingChunk = beforeReadingChunk
            let cacheWriter = cacheWriter
            analysis = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if let cached = try await Self.cachedValues(
                    fileStore: fileStore,
                    source: source,
                    bucketCount: bucketCount
                ) {
                    return cached
                }

                let generated = try await Self.generateValues(
                    fileStore: fileStore,
                    source: source,
                    bucketCount: bucketCount,
                    openAudioFile: openAudioFile,
                    beforeReadingChunk: beforeReadingChunk
                )
                try Task.checkCancellation()
                try await Self.confirmIdentities(
                    fileStore: fileStore,
                    segments: source.resolvedSegments
                )
                let snapshot = WaveformSnapshot(
                    version: WaveformSnapshot.currentVersion,
                    manifestSignature: source.manifestSignature,
                    sourceIdentitySignature: source.identitySignature,
                    values: generated
                )
                do {
                    try await cacheWriter(snapshot, source.meetingID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The waveform is already complete and usable. A cache
                    // failure should only make the next load recompute it.
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                return generated
            }
            inFlight[key] = InFlightAnalysis(
                task: analysis,
                waiters: [waiterID]
            )
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await analysis.value
            } onCancel: {
                Task {
                    await self.releaseWaiter(
                        waiterID,
                        for: key,
                        cancelled: true
                    )
                }
            }
            try Task.checkCancellation()
            releaseWaiter(waiterID, for: key, cancelled: false)
            return result
        } catch {
            releaseWaiter(
                waiterID,
                for: key,
                cancelled: Task.isCancelled
            )
            throw error
        }
    }

    private func releaseWaiter(
        _ waiterID: UUID,
        for key: AnalysisKey,
        cancelled: Bool
    ) {
        guard var current = inFlight[key],
              current.waiters.remove(waiterID) != nil else {
            return
        }
        if current.waiters.isEmpty {
            inFlight[key] = nil
            if cancelled {
                current.task.cancel()
            }
        } else {
            inFlight[key] = current
        }
    }

    static func bucketIndex(
        globalFrame: Int64,
        totalFrames: Int64,
        bucketCount: Int
    ) throws -> Int {
        guard bucketCount > 0 else {
            throw WaveformAnalyzerError.invalidBucketCount(bucketCount)
        }
        guard totalFrames > 0,
              globalFrame >= 0,
              globalFrame < totalFrames else {
            throw WaveformAnalyzerError.invalidAudioSource
        }

        let product = UInt64(globalFrame).multipliedFullWidth(
            by: UInt64(bucketCount)
        )
        let division = UInt64(totalFrames).dividingFullWidth(product)
        guard division.quotient < UInt64(bucketCount) else {
            throw WaveformAnalyzerError.invalidAudioSource
        }
        return Int(division.quotient)
    }

    private static func cachedValues(
        fileStore: MeetingFileStore,
        source: MeetingAudioSource,
        bucketCount: Int
    ) async throws -> [Float]? {
        guard source.resolvedSegments.count == source.segmentFrameCounts.count else {
            throw WaveformAnalyzerError.invalidAudioSource
        }
        let snapshot: WaveformSnapshot
        do {
            snapshot = try await fileStore.loadWaveformSnapshot(
                meetingID: source.meetingID
            )
        } catch {
            return nil
        }

        guard snapshot.version == WaveformSnapshot.currentVersion,
              snapshot.manifestSignature == source.manifestSignature,
              snapshot.sourceIdentitySignature == source.identitySignature,
              snapshot.values.count == bucketCount,
              snapshot.values.allSatisfy({ value in
                  value.isFinite && (0...1).contains(value)
              }) else {
            return nil
        }
        try Task.checkCancellation()
        try await confirmIdentities(
            fileStore: fileStore,
            segments: source.resolvedSegments
        )
        return snapshot.values
    }

    private static func generateValues(
        fileStore: MeetingFileStore,
        source: MeetingAudioSource,
        bucketCount: Int,
        openAudioFile: AudioFileOpener,
        beforeReadingChunk: BeforeReadingChunk
    ) async throws -> [Float] {
        guard source.resolvedSegments.count == source.segmentFrameCounts.count,
              source.totalFrames >= 0,
              source.sampleRate.isFinite,
              source.sampleRate > 0,
              source.channelCount > 0 else {
            throw WaveformAnalyzerError.invalidAudioSource
        }

        var validatedTotalFrames: Int64 = 0
        for frameCount in source.segmentFrameCounts {
            guard frameCount >= 0 else {
                throw WaveformAnalyzerError.invalidAudioSource
            }
            let addition = validatedTotalFrames.addingReportingOverflow(
                frameCount
            )
            guard !addition.overflow else {
                throw WaveformAnalyzerError.invalidAudioSource
            }
            validatedTotalFrames = addition.partialValue
        }
        guard validatedTotalFrames == source.totalFrames else {
            throw WaveformAnalyzerError.invalidAudioSource
        }
        try await confirmIdentities(
            fileStore: fileStore,
            segments: source.resolvedSegments
        )
        guard source.totalFrames > 0 else {
            return Array(repeating: 0, count: bucketCount)
        }

        var sumSquares = Array(repeating: 0.0, count: bucketCount)
        var sampleCounts = Array(repeating: Int64(0), count: bucketCount)
        var globalFrame: Int64 = 0

        for (segmentIndex, segment) in source.resolvedSegments.enumerated() {
            try Task.checkCancellation()
            try await confirmIdentity(
                fileStore: fileStore,
                segment: segment,
                index: segmentIndex
            )
            let audioFile: AVAudioFile
            do {
                audioFile = try openAudioFile(segment.url)
            } catch {
                try await confirmIdentity(
                    fileStore: fileStore,
                    segment: segment,
                    index: segmentIndex
                )
                throw WaveformAnalyzerError.unreadableSegment(index: segmentIndex)
            }
            try await confirmIdentity(
                fileStore: fileStore,
                segment: segment,
                index: segmentIndex
            )
            let format = audioFile.processingFormat
            let channelCount = Int(format.channelCount)
            guard format.sampleRate == source.sampleRate,
                  channelCount == source.channelCount,
                  channelCount > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format,
                      frameCapacity: maximumFramesPerRead
                  ) else {
                throw WaveformAnalyzerError.unsupportedAudioBuffer(
                    index: segmentIndex
                )
            }

            let expectedFrames = source.segmentFrameCounts[segmentIndex]
            var decodedFrames: Int64 = 0
            while decodedFrames < expectedFrames {
                try Task.checkCancellation()
                let remaining = expectedFrames - decodedFrames
                let requested = AVAudioFrameCount(
                    min(Int64(maximumFramesPerRead), remaining)
                )
                try beforeReadingChunk(requested)
                try Task.checkCancellation()
                buffer.frameLength = 0
                do {
                    try audioFile.read(into: buffer, frameCount: requested)
                } catch {
                    try await confirmIdentity(
                        fileStore: fileStore,
                        segment: segment,
                        index: segmentIndex
                    )
                    throw WaveformAnalyzerError.incompleteSegment(
                        index: segmentIndex
                    )
                }

                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0,
                      Int64(frameLength) <= remaining,
                      let channels = buffer.floatChannelData else {
                    throw WaveformAnalyzerError.incompleteSegment(
                        index: segmentIndex
                    )
                }

                for frameOffset in 0..<frameLength {
                    let frameAddition = globalFrame.addingReportingOverflow(
                        Int64(frameOffset)
                    )
                    guard !frameAddition.overflow else {
                        throw WaveformAnalyzerError.invalidAudioSource
                    }
                    let bucket = try bucketIndex(
                        globalFrame: frameAddition.partialValue,
                        totalFrames: source.totalFrames,
                        bucketCount: bucketCount
                    )
                    var frameSquare = 0.0
                    for channelIndex in 0..<channelCount {
                        let rawSample = Double(channels[channelIndex][frameOffset])
                        let sample = rawSample.isFinite
                            ? min(1, max(-1, rawSample))
                            : 0
                        frameSquare += sample * sample
                    }
                    sumSquares[bucket] += frameSquare / Double(channelCount)
                    sampleCounts[bucket] += 1
                }

                decodedFrames += Int64(frameLength)
                globalFrame += Int64(frameLength)
            }
            guard decodedFrames == expectedFrames else {
                throw WaveformAnalyzerError.incompleteSegment(index: segmentIndex)
            }
            audioFile.close()
            try await confirmIdentity(
                fileStore: fileStore,
                segment: segment,
                index: segmentIndex
            )
        }

        guard globalFrame == source.totalFrames else {
            throw WaveformAnalyzerError.invalidAudioSource
        }
        try await confirmIdentities(
            fileStore: fileStore,
            segments: source.resolvedSegments
        )
        let rootMeanSquares = zip(sumSquares, sampleCounts).map { sum, count in
            guard count > 0 else { return 0.0 }
            return sqrt(sum / Double(count))
        }
        guard let maximum = rootMeanSquares.max(),
              maximum.isFinite,
              maximum > 0 else {
            return Array(repeating: 0, count: bucketCount)
        }
        let normalizationDenominator = max(
            maximum,
            minimumNormalizationRMS
        )

        return rootMeanSquares.map { rootMeanSquare in
            let normalized = min(
                1,
                max(0, rootMeanSquare / normalizationDenominator)
            )
            let curved = sqrt(normalized)
            guard curved.isFinite else { return 0 }
            return Float(min(1, max(0, curved)))
        }
    }

    private static func confirmIdentities(
        fileStore: MeetingFileStore,
        segments: [ResolvedMeetingRecordingSegment]
    ) async throws {
        for (index, segment) in segments.enumerated() {
            try await confirmIdentity(
                fileStore: fileStore,
                segment: segment,
                index: index
            )
        }
    }

    private static func confirmIdentity(
        fileStore: MeetingFileStore,
        segment: ResolvedMeetingRecordingSegment,
        index: Int
    ) async throws {
        try Task.checkCancellation()
        do {
            try await fileStore.confirmIdentity(of: segment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WaveformAnalyzerError.segmentIdentityChanged(index: index)
        }
        try Task.checkCancellation()
    }
}
