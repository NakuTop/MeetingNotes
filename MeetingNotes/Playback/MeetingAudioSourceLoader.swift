import AVFoundation
import CryptoKit
import Foundation

struct MeetingAudioSource: Equatable, Sendable {
    let meetingID: UUID
    let segmentURLs: [URL]
    let segmentFrameCounts: [Int64]
    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64
    let manifestSignature: String

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
        case .segmentSampleRateMismatch,
             .segmentChannelCountMismatch,
             .segmentFrameCountMismatch:
            "该会议的录音文件与清单不一致。"
        }
    }
}

actor MeetingAudioSourceLoader {
    private let fileStore: MeetingFileStore
    private let fileManager: FileManager

    init(
        fileStore: MeetingFileStore,
        fileManager: FileManager = .default
    ) {
        self.fileStore = fileStore
        self.fileManager = fileManager
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

        var segmentURLs: [URL] = []
        segmentURLs.reserveCapacity(manifest.segments.count)

        for (index, segment) in manifest.segments.enumerated() {
            let url: URL
            do {
                url = try await fileStore.resolveSegmentURL(
                    meetingID: meetingID,
                    fileName: segment.fileName
                )
            } catch is MeetingFileStoreError {
                throw MeetingAudioSourceLoaderError.invalidSegmentPath(index: index)
            }

            guard fileManager.fileExists(atPath: url.path) else {
                throw MeetingAudioSourceLoaderError.segmentFileMissing(index: index)
            }

            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                throw MeetingAudioSourceLoaderError.unreadableSegment(index: index)
            }

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
            segmentURLs.append(url)
        }

        return MeetingAudioSource(
            meetingID: meetingID,
            segmentURLs: segmentURLs,
            segmentFrameCounts: manifest.segments.map(\.frameCount),
            sampleRate: manifest.sampleRate,
            channelCount: manifest.channelCount,
            totalFrames: totalFrames,
            manifestSignature: Self.manifestSignature(for: manifest)
        )
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
}
