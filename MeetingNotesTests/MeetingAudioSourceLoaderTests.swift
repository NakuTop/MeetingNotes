import AVFoundation
import XCTest
@testable import MeetingNotes

final class MeetingAudioSourceLoaderTests: XCTestCase {
    func testLoadsThreeRealCAFSegmentsInManifestOrder() async throws {
        let fixture = try await makeThreeSegmentFixture()
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        let source = try await loader.load(meetingID: fixture.meetingID)
        let secondLoad = try await loader.load(meetingID: fixture.meetingID)

        XCTAssertEqual(source.meetingID, fixture.meetingID)
        XCTAssertEqual(
            source.segmentURLs.map(\.lastPathComponent),
            ["segment-0001.caf", "segment-0002.caf", "segment-0003.caf"]
        )
        XCTAssertEqual(source.segmentFrameCounts, [3, 3, 1])
        XCTAssertEqual(source.sampleRate, 16_000, accuracy: 0.001)
        XCTAssertEqual(source.channelCount, 1)
        XCTAssertEqual(source.totalFrames, 7)
        XCTAssertEqual(source.duration, 7.0 / 16_000.0, accuracy: 0.000_000_1)
        XCTAssertFalse(source.manifestSignature.isEmpty)
        XCTAssertEqual(source.manifestSignature, secondLoad.manifestSignature)
    }

    func testManifestSignatureIsStableAndIncludesEveryPlaybackRelevantField() {
        let baseline = signatureManifest()
        let original = MeetingAudioSourceLoader.manifestSignature(for: baseline)
        XCTAssertEqual(
            original,
            MeetingAudioSourceLoader.manifestSignature(for: baseline)
        )

        let changedManifests = [
            AudioSegmentManifest(
                version: baseline.version + 1,
                sampleRate: baseline.sampleRate,
                channelCount: baseline.channelCount,
                segments: baseline.segments
            ),
            AudioSegmentManifest(
                version: baseline.version,
                sampleRate: 48_000,
                channelCount: baseline.channelCount,
                segments: baseline.segments
            ),
            AudioSegmentManifest(
                version: baseline.version,
                sampleRate: baseline.sampleRate,
                channelCount: 2,
                segments: baseline.segments
            ),
            AudioSegmentManifest(
                version: baseline.version,
                sampleRate: baseline.sampleRate,
                channelCount: baseline.channelCount,
                segments: [segment(fileName: "renamed.caf", frameCount: 3)]
            ),
            AudioSegmentManifest(
                version: baseline.version,
                sampleRate: baseline.sampleRate,
                channelCount: baseline.channelCount,
                segments: [segment(fileName: "segment-0001.caf", frameCount: 4)]
            ),
            AudioSegmentManifest(
                version: baseline.version,
                sampleRate: baseline.sampleRate,
                channelCount: baseline.channelCount,
                segments: [segment(
                    fileName: "segment-0001.caf",
                    frameCount: 3,
                    isComplete: false
                )]
            )
        ]

        for manifest in changedManifests {
            XCTAssertNotEqual(
                MeetingAudioSourceLoader.manifestSignature(for: manifest),
                original
            )
        }
    }

    func testRejectsMissingManifest() async throws {
        let fixture = try makeFixture()
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .manifestNotFound
        )
    }

    func testMapsMalformedManifestToAPathFreeLoaderError() async throws {
        let fixture = try makeFixture()
        let meetingDirectory = fixture.root.appendingPathComponent(
            fixture.meetingID.uuidString
        )
        try FileManager.default.createDirectory(
            at: meetingDirectory,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: meetingDirectory.appendingPathComponent(
                MeetingFileStore.manifestFileName
            )
        )
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        do {
            _ = try await loader.load(meetingID: fixture.meetingID)
            XCTFail("Expected unreadable manifest")
        } catch {
            XCTAssertEqual(
                error as? MeetingAudioSourceLoaderError,
                .unreadableManifest
            )
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
        }
    }

    func testRejectsEmptyManifest() async throws {
        let fixture = try makeFixture()
        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(),
            meetingID: fixture.meetingID
        )
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .emptyManifest
        )
    }

    func testRejectsUnsupportedManifestVersion() async throws {
        let fixture = try makeFixture()
        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(version: AudioSegmentManifest.currentVersion + 1),
            meetingID: fixture.meetingID
        )
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .unsupportedManifestVersion(
                AudioSegmentManifest.currentVersion + 1
            )
        )
    }

    func testRejectsInvalidManifestFormat() async throws {
        let fixture = try makeFixture()
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(sampleRate: 0),
            meetingID: fixture.meetingID
        )
        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .invalidManifestSampleRate
        )

        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(channelCount: 0),
            meetingID: fixture.meetingID
        )
        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .invalidManifestChannelCount(0)
        )
    }

    func testRejectsAnyIncompleteSegment() async throws {
        let fixture = try await makeThreeSegmentFixture()
        var manifest = try await fixture.fileStore.loadManifest(
            meetingID: fixture.meetingID
        )
        manifest.segments[1].isComplete = false
        try await fixture.fileStore.saveManifest(manifest, meetingID: fixture.meetingID)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .incompleteSegment(index: 1)
        )
    }

    func testRejectsNegativeFrameCountAndOverflow() async throws {
        let fixture = try makeFixture()
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(segments: [
                segment(fileName: "negative.caf", frameCount: -1)
            ]),
            meetingID: fixture.meetingID
        )
        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .invalidSegmentFrameCount(index: 0)
        )

        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(segments: [
                segment(fileName: "first.caf", frameCount: .max),
                segment(fileName: "second.caf", frameCount: 1)
            ]),
            meetingID: fixture.meetingID
        )
        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .totalFrameCountOverflow
        )
    }

    func testRejectsMissingSegmentFile() async throws {
        let fixture = try await makeThreeSegmentFixture()
        let segmentURL = try await fixture.fileStore.resolveSegmentURL(
            meetingID: fixture.meetingID,
            fileName: "segment-0002.caf"
        )
        try FileManager.default.removeItem(at: segmentURL)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .segmentFileMissing(index: 1)
        )
    }

    func testRejectsUnreadableCAF() async throws {
        let fixture = try await makeThreeSegmentFixture()
        let segmentURL = try await fixture.fileStore.resolveSegmentURL(
            meetingID: fixture.meetingID,
            fileName: "segment-0001.caf"
        )
        try Data("not a caf".utf8).write(to: segmentURL)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .unreadableSegment(index: 0)
        )
    }

    func testRejectsManifestFrameCountThatDiffersFromCAFLength() async throws {
        let fixture = try await makeThreeSegmentFixture()
        var manifest = try await fixture.fileStore.loadManifest(
            meetingID: fixture.meetingID
        )
        manifest.segments[0].frameCount = 2
        try await fixture.fileStore.saveManifest(manifest, meetingID: fixture.meetingID)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .segmentFrameCountMismatch(index: 0, expected: 2, actual: 3)
        )
    }

    func testRejectsCAFWithMismatchedSampleRate() async throws {
        let fixture = try await makeThreeSegmentFixture()
        let segmentURL = try await fixture.fileStore.resolveSegmentURL(
            meetingID: fixture.meetingID,
            fileName: "segment-0001.caf"
        )
        try replaceAudioFile(at: segmentURL, sampleRate: 48_000, channelCount: 1)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .segmentSampleRateMismatch(
                index: 0,
                expected: 16_000,
                actual: 48_000
            )
        )
    }

    func testRejectsCAFWithMismatchedChannelCount() async throws {
        let fixture = try await makeThreeSegmentFixture()
        let segmentURL = try await fixture.fileStore.resolveSegmentURL(
            meetingID: fixture.meetingID,
            fileName: "segment-0001.caf"
        )
        try replaceAudioFile(at: segmentURL, sampleRate: 16_000, channelCount: 2)
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .segmentChannelCountMismatch(index: 0, expected: 1, actual: 2)
        )
    }

    func testRejectsParentTraversalAndAbsoluteSegmentFilenames() async throws {
        let fixture = try makeFixture()
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        for fileName in ["../outside.caf", "/tmp/outside.caf"] {
            try await fixture.fileStore.saveManifest(
                AudioSegmentManifest(segments: [
                    segment(fileName: fileName, frameCount: 1)
                ]),
                meetingID: fixture.meetingID
            )

            do {
                _ = try await loader.load(meetingID: fixture.meetingID)
                XCTFail("Expected invalid segment path")
            } catch {
                XCTAssertEqual(
                    error as? MeetingAudioSourceLoaderError,
                    .invalidSegmentPath(index: 0)
                )
                XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
            }
        }
    }

    func testRejectsSegmentSymlinkThatEscapesMeetingDirectory() async throws {
        let fixture = try makeFixture()
        let meetingDirectory = try await fixture.fileStore.prepareMeetingDirectory(
            for: fixture.meetingID
        )
        let outside = fixture.root.appendingPathComponent("outside.caf")
        try writeAudioFile(at: outside, sampleRate: 16_000, channelCount: 1)
        let link = meetingDirectory.appendingPathComponent("segment-0001.caf")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(segments: [
                segment(fileName: link.lastPathComponent, frameCount: 3)
            ]),
            meetingID: fixture.meetingID
        )
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .invalidSegmentPath(index: 0)
        )
    }

    func testRejectsMeetingDirectorySymlinkAlias() async throws {
        let fixture = try makeFixture()
        let targetMeetingID = UUID()
        let writer = try SegmentedPCMWriter(
            meetingID: targetMeetingID,
            fileStore: fixture.fileStore,
            frameLimit: 3
        )
        try await writer.append(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: 16_000,
                samples: [0.1, 0.2, 0.3]
            )
        )
        _ = try await writer.finish()
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(fixture.meetingID.uuidString),
            withDestinationURL: fixture.root.appendingPathComponent(
                targetMeetingID.uuidString
            )
        )
        let loader = MeetingAudioSourceLoader(fileStore: fixture.fileStore)

        await assertLoaderError(
            try await loader.load(meetingID: fixture.meetingID),
            equals: .invalidSegmentPath(index: 0)
        )
    }

    private func signatureManifest() -> AudioSegmentManifest {
        AudioSegmentManifest(segments: [
            segment(fileName: "segment-0001.caf", frameCount: 3)
        ])
    }

    private func segment(
        fileName: String,
        frameCount: Int64,
        isComplete: Bool = true
    ) -> AudioSegmentManifest.Segment {
        .init(
            fileName: fileName,
            startTime: 0,
            endTime: Double(frameCount) / 16_000,
            frameCount: frameCount,
            isComplete: isComplete
        )
    }

    private func makeThreeSegmentFixture() async throws -> Fixture {
        let fixture = try makeFixture()
        let writer = try SegmentedPCMWriter(
            meetingID: fixture.meetingID,
            fileStore: fixture.fileStore,
            frameLimit: 3
        )
        try await writer.append(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: 16_000,
                samples: (0..<7).map { Float($0) / 7 }
            )
        )
        _ = try await writer.finish()
        return fixture
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioSourceLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            fileStore: MeetingFileStore(rootURL: root),
            meetingID: UUID()
        )
    }

    private func replaceAudioFile(
        at url: URL,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws {
        try FileManager.default.removeItem(at: url)
        try writeAudioFile(
            at: url,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    private func writeAudioFile(
        at url: URL,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)
        )
        buffer.frameLength = 3
        for channelIndex in 0..<Int(channelCount) {
            let channel = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
            channel[0] = 0.1
            channel[1] = 0.2
            channel[2] = 0.3
        }
        try file.write(from: buffer)
        file.close()
    }

    private func assertLoaderError<T>(
        _ expression: @autoclosure () async throws -> T,
        equals expected: MeetingAudioSourceLoaderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected source loader error", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MeetingAudioSourceLoaderError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private struct Fixture {
    let root: URL
    let fileStore: MeetingFileStore
    let meetingID: UUID
}
