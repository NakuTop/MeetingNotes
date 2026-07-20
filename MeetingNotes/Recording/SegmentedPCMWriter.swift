import AVFoundation
import Foundation

enum SegmentedPCMWriterError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Double)
    case unsupportedChannelCount(Int)
    case invalidFrameLimit(Int)
    case audioFormatUnavailable
    case audioBufferUnavailable
    case alreadyFinished
}

actor SegmentedPCMWriter {
    static let productionSegmentDuration: Double = 15

    private let meetingID: UUID
    private let fileStore: MeetingFileStore
    private let frameLimit: Int
    private let format: AVAudioFormat

    private var manifest = AudioSegmentManifest()
    private var currentFile: AVAudioFile?
    private var currentFileURL: URL?
    private var isFinished = false

    init(
        meetingID: UUID,
        fileStore: MeetingFileStore,
        frameLimit: Int? = nil,
        sampleRate: Double = AudioSegmentManifest.transcriptionSampleRate
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SegmentedPCMWriterError.audioFormatUnavailable
        }
        let resolvedRate = sampleRate
        let resolvedFrameLimit = frameLimit
            ?? Int(Self.productionSegmentDuration * resolvedRate)
        guard resolvedFrameLimit > 0,
              resolvedFrameLimit <= Int(UInt32.max) else {
            throw SegmentedPCMWriterError.invalidFrameLimit(resolvedFrameLimit)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedRate,
            channels: AVAudioChannelCount(
                AudioSegmentManifest.transcriptionChannelCount
            ),
            interleaved: false
        ) else {
            throw SegmentedPCMWriterError.audioFormatUnavailable
        }

        self.meetingID = meetingID
        self.fileStore = fileStore
        self.frameLimit = resolvedFrameLimit
        self.format = format
        manifest = AudioSegmentManifest(sampleRate: resolvedRate)
    }

    func append(_ frame: CapturedAudioFrame) async throws {
        guard !isFinished else {
            throw SegmentedPCMWriterError.alreadyFinished
        }
        guard abs(frame.sampleRate - manifest.sampleRate) < 0.001 else {
            throw SegmentedPCMWriterError.unsupportedSampleRate(frame.sampleRate)
        }
        guard frame.channelCount == manifest.channelCount else {
            throw SegmentedPCMWriterError.unsupportedChannelCount(frame.channelCount)
        }
        guard !frame.samples.isEmpty else {
            return
        }

        var sourceOffset = 0
        while sourceOffset < frame.samples.count {
            if currentFile == nil {
                let segmentStart = frame.timestamp
                    + Double(sourceOffset) / frame.sampleRate
                try await openSegment(startTime: segmentStart)
            }

            let segmentIndex = manifest.segments.index(before: manifest.segments.endIndex)
            let writtenInSegment = Int(manifest.segments[segmentIndex].frameCount)
            let remainingCapacity = frameLimit - writtenInSegment
            let chunkCount = min(
                remainingCapacity,
                frame.samples.count - sourceOffset
            )

            try write(
                samples: frame.samples,
                sourceOffset: sourceOffset,
                frameCount: chunkCount
            )
            sourceOffset += chunkCount
            manifest.segments[segmentIndex].frameCount += Int64(chunkCount)
            manifest.segments[segmentIndex].endTime = frame.timestamp
                + Double(sourceOffset) / frame.sampleRate

            if manifest.segments[segmentIndex].frameCount == Int64(frameLimit) {
                try await closeCurrentSegment()
            }
        }
    }

    func manifestSnapshot() -> AudioSegmentManifest {
        manifest
    }

    func finish() async throws -> AudioSegmentManifest {
        if !isFinished {
            try await closeCurrentSegment()
            try await fileStore.saveManifest(manifest, meetingID: meetingID)
            isFinished = true
        }
        return manifest
    }

    private func openSegment(startTime: TimeInterval) async throws {
        let directory = try await fileStore.prepareMeetingDirectory(for: meetingID)
        let fileName = String(
            format: "segment-%04d.caf",
            manifest.segments.count + 1
        )
        let fileURL = directory.appendingPathComponent(fileName)
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        currentFile = file
        currentFileURL = fileURL
        manifest.segments.append(
            .init(
                fileName: fileName,
                startTime: startTime,
                endTime: startTime,
                frameCount: 0,
                isComplete: false
            )
        )
        try await fileStore.saveManifest(manifest, meetingID: meetingID)
    }

    private func write(
        samples: [Float],
        sourceOffset: Int,
        frameCount: Int
    ) throws {
        guard let currentFile,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.floatChannelData?.pointee else {
            throw SegmentedPCMWriterError.audioBufferUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            channel[index] = samples[sourceOffset + index]
        }
        try currentFile.write(from: buffer)
    }

    private func closeCurrentSegment() async throws {
        guard let file = currentFile,
              let fileURL = currentFileURL,
              let segmentIndex = manifest.segments.indices.last else {
            return
        }

        file.close()
        currentFile = nil
        currentFileURL = nil

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        try handle.close()

        manifest.segments[segmentIndex].isComplete = true
        try await fileStore.saveManifest(manifest, meetingID: meetingID)
    }
}
