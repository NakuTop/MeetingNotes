import AVFoundation
import CryptoKit
import Foundation

struct MeetingAudioSource: Equatable, Sendable {
    let meetingID: UUID
    let resolvedSegments: [ResolvedMeetingRecordingSegment]
    let segmentFrameCounts: [Int64]
    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64
    let manifestSignature: String
    let identitySignature: String

    var segmentURLs: [URL] {
        resolvedSegments.map(\.url)
    }

    var duration: TimeInterval {
        Double(totalFrames) / sampleRate
    }
}

enum MeetingAudioSourceLoaderError: Error, Equatable, Sendable {
    case manifestNotFound
    case unreadableManifest
    case unsupportedManifestVersion(Int)
    case invalidManifestSampleRate
    case invalidManifestChannelCount(Int)
    case emptyManifest
    case incompleteSegment(index: Int)
    case invalidSegmentFrameCount(index: Int)
    case totalFrameCountOverflow
    case invalidSegmentPath(index: Int)
    case segmentFileMissing(index: Int)
    case unreadableSegment(index: Int)
    case incompleteSegmentData(index: Int)
    case segmentIdentityChanged(index: Int)
    case segmentSampleRateMismatch(index: Int, expected: Double, actual: Double)
    case segmentChannelCountMismatch(index: Int, expected: Int, actual: Int)
    case segmentFrameCountMismatch(index: Int, expected: Int64, actual: Int64)
}

extension MeetingAudioSourceLoaderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            "未找到该会议的录音清单。"
        case .unreadableManifest:
            "该会议的录音清单无法读取。"
        case .unsupportedManifestVersion:
            "该会议的录音格式版本不受支持。"
        case .invalidManifestSampleRate, .invalidManifestChannelCount:
            "该会议的录音格式无效。"
        case .emptyManifest:
            "该会议没有可播放的录音。"
        case .incompleteSegment:
            "该会议的录音尚未完整保存。"
        case .invalidSegmentFrameCount, .totalFrameCountOverflow:
            "该会议的录音长度信息无效。"
        case .invalidSegmentPath:
            "该会议的录音位置无效。"
        case .segmentFileMissing:
            "该会议的部分录音文件已丢失。"
        case .unreadableSegment:
            "该会议的部分录音无法读取。"
        case .incompleteSegmentData:
            "该会议的部分录音数据不完整。"
        case .segmentIdentityChanged:
            "该会议的录音文件在读取时发生了变化。"
        case .segmentSampleRateMismatch,
             .segmentChannelCountMismatch,
             .segmentFrameCountMismatch:
            "该会议的录音文件与清单不一致。"
        }
    }
}

actor MeetingAudioSourceLoader {
    typealias BeforeOpeningSegment = @Sendable (URL, Int) async throws -> Void

    private let fileStore: MeetingFileStore
    private let beforeOpeningSegment: BeforeOpeningSegment

    init(
        fileStore: MeetingFileStore,
        beforeOpeningSegment: @escaping BeforeOpeningSegment = { _, _ in }
    ) {
        self.fileStore = fileStore
        self.beforeOpeningSegment = beforeOpeningSegment
    }

    func load(meetingID: UUID) async throws -> MeetingAudioSource {
        let manifest: AudioSegmentManifest
        do {
            manifest = try await fileStore.loadManifest(meetingID: meetingID)
        } catch MeetingFileStoreError.manifestNotFound {
            throw MeetingAudioSourceLoaderError.manifestNotFound
        } catch {
            throw MeetingAudioSourceLoaderError.unreadableManifest
        }

        try Self.validateHeader(manifest)
        guard !manifest.segments.isEmpty else {
            throw MeetingAudioSourceLoaderError.emptyManifest
        }

        var totalFrames: Int64 = 0
        for (index, segment) in manifest.segments.enumerated() {
            guard segment.isComplete else {
                throw MeetingAudioSourceLoaderError.incompleteSegment(index: index)
            }
            guard segment.frameCount >= 0 else {
                throw MeetingAudioSourceLoaderError.invalidSegmentFrameCount(
                    index: index
                )
            }
            let addition = totalFrames.addingReportingOverflow(segment.frameCount)
            guard !addition.overflow else {
                throw MeetingAudioSourceLoaderError.totalFrameCountOverflow
            }
            totalFrames = addition.partialValue
        }

        var resolvedSegments: [ResolvedMeetingRecordingSegment] = []
        resolvedSegments.reserveCapacity(manifest.segments.count)

        for (index, segment) in manifest.segments.enumerated() {
            let resolvedSegment: ResolvedMeetingRecordingSegment
            do {
                resolvedSegment = try await fileStore.resolveSegment(
                    meetingID: meetingID,
                    fileName: segment.fileName
                )
            } catch MeetingFileStoreError.segmentNotFound {
                throw MeetingAudioSourceLoaderError.segmentFileMissing(
                    index: index
                )
            } catch is MeetingFileStoreError {
                throw MeetingAudioSourceLoaderError.invalidSegmentPath(index: index)
            }

            try await beforeOpeningSegment(resolvedSegment.url, index)
            try await confirmIdentity(of: resolvedSegment, segmentIndex: index)

            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: resolvedSegment.url)
            } catch {
                try await confirmIdentity(
                    of: resolvedSegment,
                    segmentIndex: index
                )
                throw MeetingAudioSourceLoaderError.unreadableSegment(index: index)
            }
            try await confirmIdentity(of: resolvedSegment, segmentIndex: index)

            let actualSampleRate = audioFile.fileFormat.sampleRate
            guard actualSampleRate == manifest.sampleRate else {
                throw MeetingAudioSourceLoaderError.segmentSampleRateMismatch(
                    index: index,
                    expected: manifest.sampleRate,
                    actual: actualSampleRate
                )
            }

            let actualChannelCount = Int(audioFile.fileFormat.channelCount)
            guard actualChannelCount == manifest.channelCount else {
                throw MeetingAudioSourceLoaderError.segmentChannelCountMismatch(
                    index: index,
                    expected: manifest.channelCount,
                    actual: actualChannelCount
                )
            }

            let actualFrameCount = Int64(audioFile.length)
            guard actualFrameCount == segment.frameCount else {
                throw MeetingAudioSourceLoaderError.segmentFrameCountMismatch(
                    index: index,
                    expected: segment.frameCount,
                    actual: actualFrameCount
                )
            }
            do {
                try Self.validateDecodableFrames(
                    audioFile,
                    expectedFrameCount: segment.frameCount,
                    segmentIndex: index
                )
            } catch {
                try await confirmIdentity(
                    of: resolvedSegment,
                    segmentIndex: index
                )
                throw error
            }
            try await confirmIdentity(of: resolvedSegment, segmentIndex: index)
            resolvedSegments.append(resolvedSegment)
        }

        return MeetingAudioSource(
            meetingID: meetingID,
            resolvedSegments: resolvedSegments,
            segmentFrameCounts: manifest.segments.map(\.frameCount),
            sampleRate: manifest.sampleRate,
            channelCount: manifest.channelCount,
            totalFrames: totalFrames,
            manifestSignature: Self.manifestSignature(for: manifest),
            identitySignature: Self.identitySignature(
                for: resolvedSegments
            )
        )
    }

    static func identitySignature(
        for segments: [ResolvedMeetingRecordingSegment]
    ) -> String {
        var canonical = "segmentCount:\(segments.count)\n"
        for (index, segment) in segments.enumerated() {
            canonical += "segment:\(index)\n"
            canonical += "directoryDevice:\(segment.meetingDirectoryIdentity.deviceID)\n"
            canonical += "directoryInode:\(segment.meetingDirectoryIdentity.inodeNumber)\n"
            canonical += "fileDevice:\(segment.fileIdentity.deviceID)\n"
            canonical += "fileInode:\(segment.fileIdentity.inodeNumber)\n"
        }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func manifestSignature(
        for manifest: AudioSegmentManifest
    ) -> String {
        var canonical = "version:\(manifest.version)\n"
        canonical += "sampleRateBits:\(manifest.sampleRate.bitPattern)\n"
        canonical += "channelCount:\(manifest.channelCount)\n"
        canonical += "segmentCount:\(manifest.segments.count)\n"
        for segment in manifest.segments {
            canonical += "fileNameBytes:\(segment.fileName.utf8.count):"
            canonical += segment.fileName
            canonical += "\nframeCount:\(segment.frameCount)\n"
            canonical += "complete:\(segment.isComplete ? 1 : 0)\n"
        }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHeader(
        _ manifest: AudioSegmentManifest
    ) throws {
        guard manifest.version == AudioSegmentManifest.currentVersion else {
            throw MeetingAudioSourceLoaderError.unsupportedManifestVersion(
                manifest.version
            )
        }
        guard manifest.sampleRate.isFinite,
              manifest.sampleRate == AudioSegmentManifest.transcriptionSampleRate else {
            throw MeetingAudioSourceLoaderError.invalidManifestSampleRate
        }
        guard manifest.channelCount == AudioSegmentManifest.transcriptionChannelCount else {
            throw MeetingAudioSourceLoaderError.invalidManifestChannelCount(
                manifest.channelCount
            )
        }
    }

    private func confirmIdentity(
        of segment: ResolvedMeetingRecordingSegment,
        segmentIndex: Int
    ) async throws {
        do {
            try await fileStore.confirmIdentity(of: segment)
        } catch {
            throw MeetingAudioSourceLoaderError.segmentIdentityChanged(
                index: segmentIndex
            )
        }
    }

    private static func validateDecodableFrames(
        _ audioFile: AVAudioFile,
        expectedFrameCount: Int64,
        segmentIndex: Int
    ) throws {
        let maximumFramesPerRead: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: maximumFramesPerRead
        ) else {
            throw MeetingAudioSourceLoaderError.unreadableSegment(
                index: segmentIndex
            )
        }

        var decodedFrames: Int64 = 0
        while decodedFrames < expectedFrameCount {
            let remainingFrames = expectedFrameCount - decodedFrames
            let requestedFrames = AVAudioFrameCount(
                min(Int64(maximumFramesPerRead), remainingFrames)
            )
            buffer.frameLength = 0

            do {
                try audioFile.read(
                    into: buffer,
                    frameCount: requestedFrames
                )
            } catch {
                throw MeetingAudioSourceLoaderError.incompleteSegmentData(
                    index: segmentIndex
                )
            }

            let decodedThisRead = Int64(buffer.frameLength)
            guard decodedThisRead > 0 else {
                throw MeetingAudioSourceLoaderError.incompleteSegmentData(
                    index: segmentIndex
                )
            }
            let addition = decodedFrames.addingReportingOverflow(
                decodedThisRead
            )
            guard !addition.overflow,
                  addition.partialValue <= expectedFrameCount else {
                throw MeetingAudioSourceLoaderError.incompleteSegmentData(
                    index: segmentIndex
                )
            }
            decodedFrames = addition.partialValue
        }

        guard decodedFrames == expectedFrameCount else {
            throw MeetingAudioSourceLoaderError.incompleteSegmentData(
                index: segmentIndex
            )
        }
    }
}
