import AVFoundation
import XCTest
@testable import MeetingNotes

final class SegmentedPCMWriterTests: XCTestCase {
    func testWritesAndDescribes48kPlaybackAudio() async throws {
        let root = try makeTemporaryRoot()
        let fileStore = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let writer = try SegmentedPCMWriter(
            meetingID: meetingID,
            fileStore: fileStore,
            frameLimit: 48_000,
            sampleRate: 48_000
        )
        try await writer.append(CapturedAudioFrame(
            timestamp: 0,
            sampleRate: 48_000,
            samples: sineWave(frameCount: 48_000, sampleRate: 48_000)
        ))

        let manifest = try await writer.finish()
        let segmentURL = try await fileStore.resolveSegmentURL(
            meetingID: meetingID,
            fileName: try XCTUnwrap(manifest.segments.first?.fileName)
        )
        let audioFile = try AVAudioFile(forReading: segmentURL)

        XCTAssertEqual(manifest.sampleRate, 48_000)
        XCTAssertEqual(manifest.segments.first?.frameCount, 48_000)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(audioFile.length, 48_000)
    }

    func testWritesMultipleReadableCAFSegmentsAndCompletesManifest() async throws {
        let root = try makeTemporaryRoot()
        let fileStore = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let writer = try SegmentedPCMWriter(
            meetingID: meetingID,
            fileStore: fileStore,
            frameLimit: 128
        )
        let samples = sineWave(frameCount: 400)
        let frame = CapturedAudioFrame(
            timestamp: 0,
            sampleRate: 16_000,
            samples: samples
        )

        try await writer.append(frame)

        let openSnapshot = await writer.manifestSnapshot()
        XCTAssertEqual(openSnapshot.segments.count, 4)
        XCTAssertEqual(
            openSnapshot.segments.map(\.isComplete),
            [true, true, true, false]
        )
        let persistedOpenManifest = try await fileStore.loadManifest(meetingID: meetingID)
        XCTAssertEqual(
            persistedOpenManifest.segments.map(\.isComplete),
            [true, true, true, false]
        )

        let manifest = try await writer.finish()

        XCTAssertEqual(manifest.version, AudioSegmentManifest.currentVersion)
        XCTAssertEqual(manifest.sampleRate, 16_000, accuracy: 0.001)
        XCTAssertEqual(manifest.channelCount, 1)
        XCTAssertEqual(manifest.segments.count, 4)
        XCTAssertTrue(manifest.segments.allSatisfy(\.isComplete))
        XCTAssertEqual(manifest.segments.map(\.frameCount), [128, 128, 128, 16])
        XCTAssertEqual(
            manifest.segments.reduce(Int64(0)) { $0 + $1.frameCount },
            Int64(samples.count)
        )
        let persistedFinalManifest = try await fileStore.loadManifest(meetingID: meetingID)
        XCTAssertEqual(persistedFinalManifest, manifest)

        var readableFrameCount: AVAudioFramePosition = 0
        for segment in manifest.segments {
            let relativePath = "\(meetingID.uuidString)/\(segment.fileName)"
            let url = try await fileStore.resolve(relativePath: relativePath)
            let audioFile = try AVAudioFile(forReading: url)
            XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000, accuracy: 0.001)
            XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
            readableFrameCount += audioFile.length
        }
        XCTAssertEqual(readableFrameCount, AVAudioFramePosition(samples.count))
    }

    func testRejectsUnsupportedSampleRateAndChannelCount() async throws {
        let root = try makeTemporaryRoot()
        let fileStore = MeetingFileStore(rootURL: root)
        let writer = try SegmentedPCMWriter(
            meetingID: UUID(),
            fileStore: fileStore,
            frameLimit: 128
        )

        do {
            try await writer.append(
                CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: 48_000,
                    samples: [0]
                )
            )
            XCTFail("Expected unsupported sample rate")
        } catch {
            XCTAssertEqual(
                error as? SegmentedPCMWriterError,
                .unsupportedSampleRate(48_000)
            )
        }

        do {
            try await writer.append(
                CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: 16_000,
                    channelCount: 2,
                    samples: [0, 0]
                )
            )
            XCTFail("Expected unsupported channel count")
        } catch {
            XCTAssertEqual(
                error as? SegmentedPCMWriterError,
                .unsupportedChannelCount(2)
            )
        }
    }

    func testFinishWithoutFramesProducesEmptyManifestAndCannotAppendAgain() async throws {
        let root = try makeTemporaryRoot()
        let fileStore = MeetingFileStore(rootURL: root)
        let writer = try SegmentedPCMWriter(
            meetingID: UUID(),
            fileStore: fileStore,
            frameLimit: 128
        )

        let manifest = try await writer.finish()
        XCTAssertTrue(manifest.segments.isEmpty)

        do {
            try await writer.append(
                CapturedAudioFrame(
                    timestamp: 0,
                    sampleRate: 16_000,
                    samples: [0]
                )
            )
            XCTFail("Expected writer to reject appends after finish")
        } catch {
            XCTAssertEqual(error as? SegmentedPCMWriterError, .alreadyFinished)
        }
    }

    private func sineWave(
        frameCount: Int,
        sampleRate: Float = 16_000
    ) -> [Float] {
        (0..<frameCount).map { index in
            sin(Float(index) * 2 * .pi * 440 / sampleRate)
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentedPCMWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
