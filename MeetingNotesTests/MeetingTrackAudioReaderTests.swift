import AVFoundation
import XCTest
@testable import MeetingNotes

final class MeetingTrackAudioReaderTests: XCTestCase {
    func testChunksResampleTwoCAFSegmentsAndPreserveAbsoluteTimeline()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeetingTrackAudioReaderTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let meetingID = UUID()
        let fileStore = MeetingFileStore(rootURL: root)
        let writer = try SegmentedPCMWriter(
            meetingID: meetingID,
            fileStore: fileStore,
            track: .microphone,
            frameLimit: 4_800,
            sampleRate: PCMConverter.playbackSampleRate
        )
        try await writer.append(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: PCMConverter.playbackSampleRate,
                samples: Array(repeating: 0.25, count: 9_600)
            )
        )
        _ = try await writer.finish()

        let sourceLoader = MeetingAudioSourceLoader(fileStore: fileStore)
        let source = try await sourceLoader.load(
            meetingID: meetingID,
            track: .microphone
        )
        XCTAssertEqual(source.segmentFrameCounts, [4_800, 4_800])
        XCTAssertEqual(source.segmentStartTimes, [0, 0.1])
        for url in source.segmentURLs {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 4_800)
            XCTAssertEqual(
                file.processingFormat.sampleRate,
                PCMConverter.playbackSampleRate
            )
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            file.close()
        }

        let reader = MeetingTrackAudioReader(
            sourceLoader: sourceLoader,
            maximumChunkSampleCount: 700
        )
        let sequence = try await reader.chunks(
            meetingID: meetingID,
            track: .microphone
        )
        var chunks: [MeetingAudioSampleChunk] = []
        do {
            for try await chunk in sequence {
                chunks.append(chunk)
            }
        } catch {
            XCTFail(
                "Reader failed after \(chunks.count) chunks: \(error)"
            )
            return
        }

        XCTAssertEqual(chunks.flatMap(\.samples).count, 3_200)
        XCTAssertTrue(chunks.allSatisfy { !$0.samples.isEmpty })
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count <= 700 })
        XCTAssertEqual(chunks.first?.startingAt, 0)
        XCTAssertTrue(
            chunks.contains {
                abs($0.startingAt - 0.1) < 0.000_001
            }
        )
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(
                pair.1.startingAt,
                pair.0.startingAt
                    + Double(pair.0.samples.count)
                    / AudioSegmentManifest.transcriptionSampleRate,
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(
            chunks.flatMap(\.samples)[1_600],
            0.25,
            accuracy: 0.001
        )
    }
}
