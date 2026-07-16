import AVFoundation
import XCTest
@testable import MeetingNotes

final class WaveformAnalyzerTests: XCTestCase {
    func testRejectsNonPositiveBucketCounts() async throws {
        let fixture = try await makeFixture(segments: [[0]])
        let analyzer = WaveformAnalyzer(fileStore: fixture.fileStore)

        for bucketCount in [0, -1] {
            do {
                _ = try await analyzer.values(
                    for: fixture.source,
                    bucketCount: bucketCount
                )
                XCTFail("Expected invalid bucket count")
            } catch {
                XCTAssertEqual(
                    error as? WaveformAnalyzerError,
                    .invalidBucketCount(bucketCount)
                )
            }
        }
    }

    func testAnalyzesRealSilenceLowAndHighSineSegmentsWithSquareRootCurve() async throws {
        let frameCount = 400
        let fixture = try await makeFixture(segments: [
            Array(repeating: 0, count: frameCount),
            sine(amplitude: 0.25, frameCount: frameCount),
            sine(amplitude: 1, frameCount: frameCount)
        ])
        let analyzer = WaveformAnalyzer(fileStore: fixture.fileStore)

        let values = try await analyzer.values(
            for: fixture.source,
            bucketCount: 3
        )

        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertEqual(values[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(values[1], 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(values[2], values[1])
        XCTAssertEqual(values[2], 1, accuracy: 0.000_001)
    }

    func testGlobalFrameMappingContinuesAcrossSegmentBoundaries() async throws {
        let fixture = try await makeFixture(segments: [
            [0, 0],
            [1, 1]
        ])
        let analyzer = WaveformAnalyzer(fileStore: fixture.fileStore)

        let values = try await analyzer.values(
            for: fixture.source,
            bucketCount: 3
        )

        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(values[1], 1, accuracy: 0.000_001)
        XCTAssertEqual(values[2], 1, accuracy: 0.000_001)
    }

    func testMoreBucketsThanFramesLeavesEmptyBucketsAtZero() async throws {
        let fixture = try await makeFixture(segments: [[1, 1]])
        let analyzer = WaveformAnalyzer(fileStore: fixture.fileStore)

        let values = try await analyzer.values(
            for: fixture.source,
            bucketCount: 5
        )

        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], 1, accuracy: 0.000_001)
        XCTAssertEqual(values[1], 0, accuracy: 0.000_001)
        XCTAssertEqual(values[2], 1, accuracy: 0.000_001)
        XCTAssertEqual(values[3], 0, accuracy: 0.000_001)
        XCTAssertEqual(values[4], 0, accuracy: 0.000_001)
    }

    func testOverflowSafeBucketMappingHandlesLongFrameCounts() throws {
        let totalFrames = Int64.max - 1
        let bucketCount = Int(totalFrames)

        XCTAssertEqual(
            try WaveformAnalyzer.bucketIndex(
                globalFrame: totalFrames - 1,
                totalFrames: totalFrames,
                bucketCount: bucketCount
            ),
            bucketCount - 1
        )
        XCTAssertEqual(
            try WaveformAnalyzer.bucketIndex(
                globalFrame: 0,
                totalFrames: totalFrames,
                bucketCount: bucketCount
            ),
            0
        )
    }

    func testReadsLongAudioInBoundedChunks() async throws {
        let fixture = try await makeFixture(
            segments: [sine(amplitude: 0.5, frameCount: 10_000)]
        )
        let recorder = ChunkRecorder()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            beforeReadingChunk: { requestedFrameCount in
                recorder.record(requestedFrameCount)
            }
        )

        _ = try await analyzer.values(for: fixture.source, bucketCount: 10)

        XCTAssertGreaterThan(recorder.count, 1)
        XCTAssertLessThanOrEqual(recorder.maximum, 4_096)
    }

    func testMatchingCacheReturnsWithoutOpeningAudio() async throws {
        let fixture = try await makeFixture(segments: [[0.25, 0.5, 1]])
        let cachedValues: [Float] = [0.1, 0.2, 0.3]
        try await fixture.fileStore.saveWaveformSnapshot(
            WaveformSnapshot(
                version: WaveformSnapshot.currentVersion,
                manifestSignature: fixture.source.manifestSignature,
                values: cachedValues
            ),
            meetingID: fixture.meetingID
        )
        let opener = AudioOpenCounter()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            openAudioFile: { url in
                opener.recordOpen()
                return try AVAudioFile(forReading: url)
            }
        )

        let values = try await analyzer.values(
            for: fixture.source,
            bucketCount: cachedValues.count
        )

        XCTAssertEqual(values, cachedValues)
        XCTAssertEqual(opener.count, 0)
    }

    func testSignatureAndBucketCountChangesInvalidateCache() async throws {
        let fixture = try await makeFixture(segments: [[0.25, 0.5, 1, 0.5]])
        let opener = AudioOpenCounter()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            openAudioFile: { url in
                opener.recordOpen()
                return try AVAudioFile(forReading: url)
            }
        )

        _ = try await analyzer.values(for: fixture.source, bucketCount: 2)
        XCTAssertEqual(opener.count, 1)
        _ = try await analyzer.values(for: fixture.source, bucketCount: 3)
        XCTAssertEqual(opener.count, 2)

        let changedSource = try await sourceAfterRenamingFirstSegment(in: fixture)
        XCTAssertNotEqual(
            changedSource.manifestSignature,
            fixture.source.manifestSignature
        )
        _ = try await analyzer.values(for: changedSource, bucketCount: 3)
        XCTAssertEqual(opener.count, 3)
    }

    func testInvalidVersionOutOfRangeAndCorruptCachesAreRecomputed() async throws {
        let fixture = try await makeFixture(segments: [[0.25, 0.5, 1, 0.5]])
        let opener = AudioOpenCounter()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            openAudioFile: { url in
                opener.recordOpen()
                return try AVAudioFile(forReading: url)
            }
        )

        try await fixture.fileStore.saveWaveformSnapshot(
            WaveformSnapshot(
                version: WaveformSnapshot.currentVersion + 1,
                manifestSignature: fixture.source.manifestSignature,
                values: [0.2, 0.4]
            ),
            meetingID: fixture.meetingID
        )
        _ = try await analyzer.values(for: fixture.source, bucketCount: 2)
        XCTAssertEqual(opener.count, 1)

        try await fixture.fileStore.saveWaveformSnapshot(
            WaveformSnapshot(
                version: WaveformSnapshot.currentVersion,
                manifestSignature: fixture.source.manifestSignature,
                values: [-0.1, 1.1]
            ),
            meetingID: fixture.meetingID
        )
        _ = try await analyzer.values(for: fixture.source, bucketCount: 2)
        XCTAssertEqual(opener.count, 2)

        let cacheURL = fixture.root
            .appendingPathComponent(fixture.meetingID.uuidString)
            .appendingPathComponent(MeetingFileStore.waveformFileName)
        try Data("{not-json}".utf8).write(to: cacheURL)
        _ = try await analyzer.values(for: fixture.source, bucketCount: 2)
        XCTAssertEqual(opener.count, 3)

        try Data(
            """
            {"version":1,"manifestSignature":"\(fixture.source.manifestSignature)","values":[NaN,0.5]}
            """.utf8
        ).write(to: cacheURL)
        let values = try await analyzer.values(for: fixture.source, bucketCount: 2)
        XCTAssertEqual(opener.count, 4)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    func testWaveformCacheReplacementIsAtomicAndLeavesNoTemporaryFile() async throws {
        let fixture = try await makeFixture(segments: [[0.25, 0.5]])
        let first = WaveformSnapshot(
            version: WaveformSnapshot.currentVersion,
            manifestSignature: "first",
            values: [0.25]
        )
        let replacement = WaveformSnapshot(
            version: WaveformSnapshot.currentVersion,
            manifestSignature: "replacement",
            values: [0.5, 1]
        )

        try await fixture.fileStore.saveWaveformSnapshot(
            first,
            meetingID: fixture.meetingID
        )
        try await fixture.fileStore.saveWaveformSnapshot(
            replacement,
            meetingID: fixture.meetingID
        )

        let reloaded = try await fixture.fileStore.loadWaveformSnapshot(
            meetingID: fixture.meetingID
        )
        XCTAssertEqual(reloaded, replacement)
        let directory = fixture.root.appendingPathComponent(
            fixture.meetingID.uuidString
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        XCTAssertTrue(names.contains(MeetingFileStore.waveformFileName))
        XCTAssertFalse(names.contains { $0.hasPrefix(".waveform-") })
    }

    func testConcurrentRequestsShareTheCachedResult() async throws {
        let fixture = try await makeFixture(
            segments: [sine(amplitude: 0.5, frameCount: 8_000)]
        )
        let opener = AudioOpenCounter()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            openAudioFile: { url in
                opener.recordOpen()
                return try AVAudioFile(forReading: url)
            }
        )

        async let first = analyzer.values(for: fixture.source, bucketCount: 20)
        async let second = analyzer.values(for: fixture.source, bucketCount: 20)
        let results = try await (first, second)

        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(opener.count, 1)
    }

    func testCancellationStopsAnalysisAndDoesNotWritePartialCache() async throws {
        let fixture = try await makeFixture(
            segments: [sine(amplitude: 0.5, frameCount: 10_000)]
        )
        let blocker = ChunkBlocker()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            beforeReadingChunk: { _ in
                blocker.blockFirstChunk()
            }
        )
        let task = Task {
            try await analyzer.values(for: fixture.source, bucketCount: 20)
        }

        XCTAssertTrue(blocker.waitUntilBlocked(timeout: 2))
        task.cancel()
        blocker.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        do {
            _ = try await fixture.fileStore.loadWaveformSnapshot(
                meetingID: fixture.meetingID
            )
            XCTFail("Expected no partial cache")
        } catch {
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .waveformNotFound(fixture.meetingID)
            )
        }
    }

    func testCancellingAJoinedRequestCancelsSharedAnalysisAndWritesNoCache() async throws {
        let fixture = try await makeFixture(
            segments: [sine(amplitude: 0.5, frameCount: 10_000)]
        )
        let blocker = ChunkBlocker()
        let analyzer = WaveformAnalyzer(
            fileStore: fixture.fileStore,
            beforeReadingChunk: { _ in
                blocker.blockFirstChunk()
            }
        )
        let first = Task {
            try await analyzer.values(for: fixture.source, bucketCount: 20)
        }
        XCTAssertTrue(blocker.waitUntilBlocked(timeout: 2))
        let joined = Task {
            try await analyzer.values(for: fixture.source, bucketCount: 20)
        }

        joined.cancel()
        blocker.release()

        await assertCancelled(joined)
        await assertCancelled(first)
        do {
            _ = try await fixture.fileStore.loadWaveformSnapshot(
                meetingID: fixture.meetingID
            )
            XCTFail("Expected no cache after shared cancellation")
        } catch {
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .waveformNotFound(fixture.meetingID)
            )
        }
    }

    private func makeFixture(segments: [[Float]]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformAnalyzerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let meetingID = UUID()
        let fileStore = MeetingFileStore(rootURL: root)
        let directory = try await fileStore.prepareMeetingDirectory(for: meetingID)
        var manifestSegments: [AudioSegmentManifest.Segment] = []
        var startTime: TimeInterval = 0

        for (offset, samples) in segments.enumerated() {
            let fileName = String(format: "segment-%04d.caf", offset + 1)
            try writeCAF(
                samples: samples,
                to: directory.appendingPathComponent(fileName)
            )
            let duration = Double(samples.count) / 16_000
            manifestSegments.append(.init(
                fileName: fileName,
                startTime: startTime,
                endTime: startTime + duration,
                frameCount: Int64(samples.count),
                isComplete: true
            ))
            startTime += duration
        }
        try await fileStore.saveManifest(
            AudioSegmentManifest(segments: manifestSegments),
            meetingID: meetingID
        )
        let source = try await MeetingAudioSourceLoader(fileStore: fileStore)
            .load(meetingID: meetingID)
        return Fixture(
            root: root,
            meetingID: meetingID,
            fileStore: fileStore,
            source: source
        )
    }

    private func sourceAfterRenamingFirstSegment(
        in fixture: Fixture
    ) async throws -> MeetingAudioSource {
        var manifest = try await fixture.fileStore.loadManifest(
            meetingID: fixture.meetingID
        )
        let oldFileName = manifest.segments[0].fileName
        let newFileName = "renamed-\(oldFileName)"
        let directory = fixture.root.appendingPathComponent(
            fixture.meetingID.uuidString
        )
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent(oldFileName),
            to: directory.appendingPathComponent(newFileName)
        )
        manifest.segments[0].fileName = newFileName
        try await fixture.fileStore.saveManifest(
            manifest,
            meetingID: fixture.meetingID
        )
        return try await MeetingAudioSourceLoader(fileStore: fixture.fileStore)
            .load(meetingID: fixture.meetingID)
    }

    private func assertCancelled<T>(
        _ task: Task<T, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private func writeCAF(samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
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
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
        file.close()
    }

    private func sine(amplitude: Float, frameCount: Int) -> [Float] {
        (0..<frameCount).map { index in
            amplitude * sin(2 * .pi * Float(index) / 4)
        }
    }
}

private struct Fixture {
    let root: URL
    let meetingID: UUID
    let fileStore: MeetingFileStore
    let source: MeetingAudioSource
}

private final class AudioOpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func recordOpen() {
        lock.withLock { storedCount += 1 }
    }
}

private final class ChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedFrameCounts: [AVAudioFrameCount] = []

    var count: Int {
        lock.withLock { requestedFrameCounts.count }
    }

    var maximum: AVAudioFrameCount {
        lock.withLock { requestedFrameCounts.max() ?? 0 }
    }

    func record(_ requestedFrameCount: AVAudioFrameCount) {
        lock.withLock { requestedFrameCounts.append(requestedFrameCount) }
    }
}

private final class ChunkBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var didBlock = false

    func blockFirstChunk() {
        let shouldBlock = lock.withLock {
            guard !didBlock else { return false }
            didBlock = true
            return true
        }
        guard shouldBlock else { return }
        reached.signal()
        resume.wait()
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        reached.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        resume.signal()
    }
}
