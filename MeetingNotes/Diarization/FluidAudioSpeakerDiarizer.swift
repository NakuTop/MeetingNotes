import AVFoundation
import FluidAudio
import Foundation
import os

protocol DiarizationEngine: Sendable {
    func prepareModels(directory: URL) async throws

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval]
}

protocol DiarizationAudioConverting: Sendable {
    func convert(
        inputURL: URL,
        rawOutputURL: URL,
        targetSampleRate: Int
    ) async throws -> Int
}

struct DiarizationTimelineLimits: Sendable {
    let maximumTimelineFrames: Int64
    let maximumSingleGapFrames: Int64
    let maximumTimelineByteCount: Int64

    // The local diarization path intentionally supports at most a 12-hour
    // stitched meeting with no single positive gap longer than 2 hours.
    static let production = DiarizationTimelineLimits(
        maximumTimelineFrames: 12 * 60 * 60 * 48_000,
        maximumSingleGapFrames: 2 * 60 * 60 * 48_000,
        maximumTimelineByteCount:
            12 * 60 * 60 * 48_000
                * Int64(MemoryLayout<Float>.stride)
    )
}

struct DiarizationDiskAudioSource: StreamingAudioSampleSource {
    private let mappedData: Data
    let fileURL: URL
    let sampleCount: Int

    init(mappedData: Data, fileURL: URL) throws {
        guard mappedData.count.isMultiple(
            of: MemoryLayout<Float>.stride
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        self.mappedData = mappedData
        self.fileURL = fileURL
        sampleCount = mappedData.count / MemoryLayout<Float>.stride
    }

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard count > 0, sampleCount > 0 else {
            return
        }
        let clampedOffset = max(0, offset)
        guard clampedOffset < sampleCount else {
            return
        }
        let available = min(sampleCount - clampedOffset, count)
        mappedData.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float.self)
            destination.update(
                from: floats.baseAddress!.advanced(by: clampedOffset),
                count: available
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

actor FluidAudioSpeakerDiarizer: SpeakerDiarizing {
    private static let sourceSampleRate = 48_000
    private static let targetSampleRate = 16_000
    private static let bufferFrameCount: AVAudioFrameCount = 16_384
    // FluidAudio 0.12.6 diarization timestamps follow the segmentation
    // model's output grid over its 10-second window, rather than exact 16 kHz
    // sample positions. One tenth of a second is a conservative frame bound.
    private static let modelFrameEndTolerance: TimeInterval = 0.1

    private let modelsDirectory: URL
    private let sourceLoader: any MeetingTrackAudioSourceLoading
    private let engine: any DiarizationEngine
    private let converter: any DiarizationAudioConverting
    private let temporaryDirectory: URL
    private let timelineLimits: DiarizationTimelineLimits
    private var modelsArePrepared = false
    private var operationIsActive = false
    private var operationWaiters: [OperationWaiter] = []

    init(
        modelsDirectory: URL,
        sourceLoader: any MeetingTrackAudioSourceLoading
    ) {
        self.modelsDirectory = modelsDirectory
        self.sourceLoader = sourceLoader
        engine = OfflineFluidAudioDiarizationEngine()
        converter = AVAudioDiarizationConverter()
        temporaryDirectory = FileManager.default.temporaryDirectory
        timelineLimits = .production
    }

    init(
        modelsDirectory: URL,
        sourceLoader: any MeetingTrackAudioSourceLoading,
        engine: any DiarizationEngine,
        converter: any DiarizationAudioConverting,
        temporaryDirectory: URL,
        timelineLimits: DiarizationTimelineLimits = .production
    ) {
        self.modelsDirectory = modelsDirectory
        self.sourceLoader = sourceLoader
        self.engine = engine
        self.converter = converter
        self.temporaryDirectory = temporaryDirectory
        self.timelineLimits = timelineLimits
    }

    func diarize(
        source: MeetingAudioSource
    ) async throws -> [SpeakerInterval] {
        try await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }
        try Task.checkCancellation()

        try await prepareModelsIfNeeded()

        let timelineAudio: PreparedTimelineAudio
        do {
            timelineAudio = try await makeTimelineAudio(for: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.inferenceFailed
        }
        defer { timelineAudio.cleanup() }

        let diskSource: DiarizationDiskAudioSource
        let loadDuration: TimeInterval
        do {
            (diskSource, loadDuration) =
                try await makeDiskBackedSource(
                    from: timelineAudio.url
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.inferenceFailed
        }
        defer { diskSource.cleanup() }

        do {
            let intervals = try await engine.process(
                audioSource: diskSource,
                audioLoadingSeconds: loadDuration
            )
            return try validatedIntervals(
                intervals,
                timelineDuration: timelineAudio.duration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.inferenceFailed
        }
    }

    private func acquireExclusiveOperation() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (
                    continuation:
                        CheckedContinuation<Void, Error>
                ) in
                if Task.isCancelled {
                    continuation.resume(
                        throwing: CancellationError()
                    )
                } else if !operationIsActive {
                    operationIsActive = true
                    continuation.resume()
                } else {
                    operationWaiters.append(
                        OperationWaiter(
                            id: waiterID,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelOperationWaiter(id: waiterID)
            }
        }
    }

    private func cancelOperationWaiter(id: UUID) {
        guard let index = operationWaiters.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        operationWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }

    private func releaseExclusiveOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        operationWaiters.removeFirst().continuation.resume()
    }

    private func prepareModelsIfNeeded() async throws {
        guard !modelsArePrepared else {
            return
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
            try await engine.prepareModels(directory: modelsDirectory)
            try Task.checkCancellation()
            modelsArePrepared = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.modelPreparationFailed
        }
    }

    private func makeTimelineAudio(
        for source: MeetingAudioSource
    ) async throws -> PreparedTimelineAudio {
        let plan = try makeTimelinePlan(for: source)

        let outputURL = temporaryDirectory.appendingPathComponent(
            "meeting-notes-diarization-\(UUID().uuidString).caf"
        )
        do {
            let format = try requiredSourceFormat()
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            defer { outputFile.close() }

            for segment in plan.segments {
                try Task.checkCancellation()
                try writeSilence(
                    frameCount: segment.gapFrames,
                    format: format,
                    to: outputFile
                )
                try await appendSegment(
                    source: source,
                    segmentIndex: segment.index,
                    expectedFrames: segment.frameCount,
                    expectedFormat: format,
                    to: outputFile
                )
            }
            outputFile.close()
            return PreparedTimelineAudio(
                url: outputURL,
                duration: Double(plan.totalFrames)
                    / Double(Self.sourceSampleRate)
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func makeTimelinePlan(
        for source: MeetingAudioSource
    ) throws -> DiarizationTimelinePlan {
        let segmentCount = source.resolvedSegments.count
        guard segmentCount > 0,
              source.segmentFrameCounts.count == segmentCount,
              source.segmentStartTimes.count == segmentCount,
              source.sampleRate == Double(Self.sourceSampleRate),
              source.channelCount == 1,
              timelineLimits.maximumTimelineFrames > 0,
              timelineLimits.maximumSingleGapFrames >= 0,
              timelineLimits.maximumSingleGapFrames
                <= timelineLimits.maximumTimelineFrames,
              timelineLimits.maximumTimelineByteCount > 0 else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        var checkedSourceFrames: Int64 = 0
        for frameCount in source.segmentFrameCounts {
            guard frameCount > 0 else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let addition = checkedSourceFrames.addingReportingOverflow(
                frameCount
            )
            guard !addition.overflow,
                  addition.partialValue
                    <= timelineLimits.maximumTimelineFrames else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            checkedSourceFrames = addition.partialValue
        }
        guard checkedSourceFrames == source.totalFrames else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        let maximumStartTime =
            Double(timelineLimits.maximumTimelineFrames)
                / Double(Self.sourceSampleRate)
        var outputFrames: Int64 = 0
        var segments: [DiarizationTimelineSegmentPlan] = []
        segments.reserveCapacity(segmentCount)

        for index in 0..<segmentCount {
            let startTime = source.segmentStartTimes[index]
            guard startTime.isFinite,
                  startTime >= 0,
                  startTime <= maximumStartTime else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let startFrameValue =
                startTime * Double(Self.sourceSampleRate)
            guard startFrameValue.isFinite,
                  startFrameValue >= 0,
                  startFrameValue
                    <= Double(timelineLimits.maximumTimelineFrames) else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let roundedStartFrame = startFrameValue.rounded()
            guard roundedStartFrame >= 0,
                  roundedStartFrame
                    <= Double(timelineLimits.maximumTimelineFrames) else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let startFrame = Int64(roundedStartFrame)

            let gap = startFrame.subtractingReportingOverflow(outputFrames)
            guard !gap.overflow,
                  gap.partialValue >= 0,
                  gap.partialValue
                    <= timelineLimits.maximumSingleGapFrames else {
                throw SpeakerDiarizationError.inferenceFailed
            }

            let frameCount = source.segmentFrameCounts[index]
            let end = startFrame.addingReportingOverflow(frameCount)
            guard !end.overflow,
                  end.partialValue
                    <= timelineLimits.maximumTimelineFrames else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let byteCount = end.partialValue
                .multipliedReportingOverflow(
                    by: Int64(MemoryLayout<Float>.stride)
                )
            guard !byteCount.overflow,
                  byteCount.partialValue
                    <= timelineLimits.maximumTimelineByteCount else {
                throw SpeakerDiarizationError.inferenceFailed
            }

            segments.append(
                DiarizationTimelineSegmentPlan(
                    index: index,
                    gapFrames: gap.partialValue,
                    frameCount: frameCount
                )
            )
            outputFrames = end.partialValue
        }

        return DiarizationTimelinePlan(
            segments: segments,
            totalFrames: outputFrames
        )
    }

    private func appendSegment(
        source: MeetingAudioSource,
        segmentIndex: Int,
        expectedFrames: Int64,
        expectedFormat: AVAudioFormat,
        to outputFile: AVAudioFile
    ) async throws {
        try await sourceLoader.confirmSegmentIdentity(
            in: source,
            segmentIndex: segmentIndex
        )
        let inputFile = try AVAudioFile(
            forReading: source.segmentURLs[segmentIndex]
        )
        do {
            try await sourceLoader.confirmSegmentIdentity(
                in: source,
                segmentIndex: segmentIndex
            )
        } catch {
            inputFile.close()
            throw error
        }
        defer { inputFile.close() }

        let inputFormat = inputFile.processingFormat
        guard inputFormat.sampleRate == expectedFormat.sampleRate,
              inputFormat.channelCount == expectedFormat.channelCount,
              inputFormat.commonFormat == .pcmFormatFloat32,
              inputFile.length == expectedFrames else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: expectedFormat,
            frameCapacity: Self.bufferFrameCount
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        var framesRead: Int64 = 0
        while framesRead < expectedFrames {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(
                min(
                    Int64(Self.bufferFrameCount),
                    expectedFrames - framesRead
                )
            )
            try inputFile.read(into: buffer, frameCount: requested)
            guard buffer.frameLength == requested else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            try outputFile.write(from: buffer)
            framesRead += Int64(requested)
        }
    }

    private func writeSilence(
        frameCount: Int64,
        format: AVAudioFormat,
        to outputFile: AVAudioFile
    ) throws {
        guard frameCount >= 0 else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        guard frameCount > 0 else {
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: Self.bufferFrameCount
        ), let channel = buffer.floatChannelData?.pointee else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        var remaining = frameCount
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(
                min(Int64(Self.bufferFrameCount), remaining)
            )
            buffer.frameLength = count
            channel.update(
                repeating: 0,
                count: Int(count)
            )
            try outputFile.write(from: buffer)
            remaining -= Int64(count)
        }
    }

    private func requiredSourceFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sourceSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        return format
    }

    private func makeDiskBackedSource(
        from audioURL: URL
    ) async throws -> (
        source: DiarizationDiskAudioSource,
        loadDuration: TimeInterval
    ) {
        let startedAt = Date()
        let rawURL = temporaryDirectory.appendingPathComponent(
            "meeting-notes-fluidaudio-\(UUID().uuidString).raw"
        )
        do {
            let convertedCount = try await converter.convert(
                inputURL: audioURL,
                rawOutputURL: rawURL,
                targetSampleRate: Self.targetSampleRate
            )
            try Task.checkCancellation()
            let mappedData = try Data(
                contentsOf: rawURL,
                options: [.mappedIfSafe]
            )
            let source = try DiarizationDiskAudioSource(
                mappedData: mappedData,
                fileURL: rawURL
            )
            guard source.sampleCount == convertedCount,
                  source.sampleCount > 0 else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            return (
                source,
                Date().timeIntervalSince(startedAt)
            )
        } catch {
            try? FileManager.default.removeItem(at: rawURL)
            throw error
        }
    }

    private func validatedIntervals(
        _ intervals: [SpeakerInterval],
        timelineDuration: TimeInterval
    ) throws -> [SpeakerInterval] {
        return try intervals.map { interval in
            let speakerID = interval.rawSpeakerID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakerID.isEmpty,
                  interval.startTime.isFinite,
                  interval.endTime.isFinite,
                  interval.startTime >= 0,
                  interval.endTime > interval.startTime,
                  interval.endTime
                    <= timelineDuration
                        + Self.modelFrameEndTolerance else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let clampedEnd = min(
                interval.endTime,
                timelineDuration
            )
            guard clampedEnd > interval.startTime else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            return SpeakerInterval(
                rawSpeakerID: speakerID,
                startTime: interval.startTime,
                endTime: clampedEnd
            )
        }
    }
}

private struct OperationWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
}

private struct PreparedTimelineAudio: Sendable {
    let url: URL
    let duration: TimeInterval

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct DiarizationTimelinePlan: Sendable {
    let segments: [DiarizationTimelineSegmentPlan]
    let totalFrames: Int64
}

private struct DiarizationTimelineSegmentPlan: Sendable {
    let index: Int
    let gapFrames: Int64
    let frameCount: Int64
}

private final class OfflineFluidAudioDiarizationEngine:
    DiarizationEngine,
    @unchecked Sendable {
    nonisolated(unsafe) private let manager: OfflineDiarizerManager

    init(manager: OfflineDiarizerManager = OfflineDiarizerManager()) {
        self.manager = manager
    }

    func prepareModels(directory: URL) async throws {
        try await manager.prepareModels(directory: directory)
    }

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval] {
        let result = try await manager.process(
            audioSource: audioSource,
            audioLoadingSeconds: audioLoadingSeconds
        )
        return result.segments.map {
            SpeakerInterval(
                rawSpeakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
    }
}

private struct AVAudioDiarizationConverter:
    DiarizationAudioConverting {
    func convert(
        inputURL: URL,
        rawOutputURL: URL,
        targetSampleRate: Int
    ) async throws -> Int {
        try Task.checkCancellation()
        let audioFile = try AVAudioFile(forReading: inputURL)
        defer { audioFile.close() }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(
            from: audioFile.processingFormat,
            to: targetFormat
        ), FileManager.default.createFile(
            atPath: rawOutputURL.path,
            contents: nil
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        let handle = try FileHandle(forWritingTo: rawOutputURL)
        defer { try? handle.close() }
        return try streamConvert(
            audioFile: audioFile,
            converter: converter,
            outputHandle: handle
        )
    }

    private func streamConvert(
        audioFile: AVAudioFile,
        converter: AVAudioConverter,
        outputHandle: FileHandle
    ) throws -> Int {
        let inputCapacity: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: inputCapacity
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        let estimatedOutputFrames = AVAudioFrameCount(
            (
                Double(inputCapacity)
                    * converter.outputFormat.sampleRate
                    / audioFile.processingFormat.sampleRate
            ).rounded(.up)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(1_024, estimatedOutputFrames)
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        let inputComplete = OSAllocatedUnfairLock(initialState: false)
        let readError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        nonisolated(unsafe) let capturedInputBuffer = inputBuffer
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if inputComplete.withLock({ $0 }) {
                status.pointee = .endOfStream
                return nil
            }
            do {
                let remaining = AVAudioFrameCount(
                    audioFile.length - audioFile.framePosition
                )
                let requested = min(inputCapacity, remaining)
                if requested > 0 {
                    try audioFile.read(
                        into: capturedInputBuffer,
                        frameCount: requested
                    )
                } else {
                    capturedInputBuffer.frameLength = 0
                }
            } catch {
                readError.withLock { $0 = error }
                capturedInputBuffer.frameLength = 0
            }
            guard capturedInputBuffer.frameLength > 0 else {
                inputComplete.withLock { $0 = true }
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return capturedInputBuffer
        }

        var totalSamples = 0
        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            if conversionError != nil {
                throw SpeakerDiarizationError.inferenceFailed
            }
            if readError.withLock({ $0 }) != nil {
                throw SpeakerDiarizationError.inferenceFailed
            }
            let producedFrames = Int(outputBuffer.frameLength)
            if producedFrames > 0 {
                guard let samples =
                    outputBuffer.floatChannelData?.pointee else {
                    throw SpeakerDiarizationError.inferenceFailed
                }
                try outputHandle.write(
                    contentsOf: Data(
                        bytes: samples,
                        count: producedFrames
                            * MemoryLayout<Float>.stride
                    )
                )
                totalSamples += producedFrames
            }
            if status == .endOfStream {
                return totalSamples
            }
        }
    }
}
