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

    func testChunksResetConverterAndPreservePositiveGapTimeline()
        async throws {
        let fixture = try await makeTwoSegmentFixture()
        var manifest = try await fixture.fileStore.loadManifest(
            meetingID: fixture.meetingID,
            track: .microphone
        )
        manifest.segments[1].startTime = 0.2
        manifest.segments[1].endTime = 0.3
        try await fixture.fileStore.saveManifest(
            manifest,
            meetingID: fixture.meetingID,
            track: .microphone
        )
        let reader = MeetingTrackAudioReader(
            sourceLoader: MeetingAudioSourceLoader(
                fileStore: fixture.fileStore
            ),
            maximumChunkSampleCount: 700
        )

        let chunks = try await collect(
            reader.chunks(
                meetingID: fixture.meetingID,
                track: .microphone
            )
        )

        XCTAssertEqual(chunks.flatMap(\.samples).count, 3_200)
        XCTAssertTrue(
            chunks.contains {
                abs($0.startingAt - 0.2) < 0.000_001
            }
        )
        XCTAssertFalse(
            chunks.contains {
                $0.startingAt > 0.1 && $0.startingAt < 0.2
            }
        )
    }

    func testStreamingConversionRetainsZeroOutputAndDrainsTail()
        async throws {
        let fixture = try await makeSingleSegmentFixture()
        let segmentReader = FakeTrackSegmentReader(
            format: .init(
                sampleRate: 48_000,
                channelCount: 1,
                isFloat32: true
            ),
            declaredFrameCount: 4_800,
            reads: [Array(repeating: 0.25, count: 4_800)]
        )
        let converter = ScriptedTrackPCMConverter(
            segmentScripts: [[
                .init(
                    samples: [],
                    inputFramesConsumed: 0,
                    needsInput: true,
                    isEndOfStream: false
                ),
                .init(
                    samples: [],
                    inputFramesConsumed: 4_800,
                    needsInput: true,
                    isEndOfStream: false
                ),
                .init(
                    samples: [0.5, 0.75],
                    inputFramesConsumed: 0,
                    needsInput: false,
                    isEndOfStream: true
                ),
            ]]
        )
        let reader = MeetingTrackAudioReader(
            sourceLoader: MeetingAudioSourceLoader(
                fileStore: fixture.fileStore
            ),
            maximumChunkSampleCount: 700,
            segmentReaderFactory: FakeTrackSegmentReaderFactory(
                readers: [segmentReader]
            ),
            converter: converter
        )

        let chunks = try await collect(
            reader.chunks(
                meetingID: fixture.meetingID,
                track: .microphone
            )
        )

        XCTAssertEqual(chunks, [
            MeetingAudioSampleChunk(
                samples: [0.5, 0.75],
                startingAt: 0
            ),
        ])
        XCTAssertEqual(converter.appendedSampleCounts(), [4_800])
        XCTAssertEqual(converter.finishInputCallCount(), 1)
        XCTAssertEqual(converter.resetCallCount(), 1)
    }

    func testStreamingConversionThrowsInsteadOfLoopingWithoutProgress()
        async throws {
        let fixture = try await makeSingleSegmentFixture()
        let segmentReader = FakeTrackSegmentReader(
            format: .init(
                sampleRate: 48_000,
                channelCount: 1,
                isFloat32: true
            ),
            declaredFrameCount: 4_800,
            reads: [Array(repeating: 0.25, count: 4_800)]
        )
        let converter = ScriptedTrackPCMConverter(
            segmentScripts: [[
                .init(
                    samples: [],
                    inputFramesConsumed: 0,
                    needsInput: true,
                    isEndOfStream: false
                ),
                .init(
                    samples: [],
                    inputFramesConsumed: 0,
                    needsInput: false,
                    isEndOfStream: false
                ),
                .init(
                    samples: [],
                    inputFramesConsumed: 0,
                    needsInput: false,
                    isEndOfStream: false
                ),
            ]]
        )
        let reader = MeetingTrackAudioReader(
            sourceLoader: MeetingAudioSourceLoader(
                fileStore: fixture.fileStore
            ),
            segmentReaderFactory: FakeTrackSegmentReaderFactory(
                readers: [segmentReader]
            ),
            converter: converter
        )

        await assertReaderError(
            try await reader.chunks(
                meetingID: fixture.meetingID,
                track: .microphone
            ),
            equals: .conversionStalled(index: 0)
        )
    }

    func testReopenRejectsChangedIdentityFormatAndDeclaredLength()
        async throws {
        do {
            let fixture = try await makeSingleSegmentFixture()
            let reader = MeetingTrackAudioReader(
                sourceLoader: MeetingAudioSourceLoader(
                    fileStore: fixture.fileStore
                )
            )
            let sequence = try await reader.chunks(
                meetingID: fixture.meetingID,
                track: .microphone
            )
            let url = try await fixture.fileStore.resolveSegmentURL(
                meetingID: fixture.meetingID,
                fileName: "microphone-segment-0001.caf"
            )
            let replacement = fixture.root.appendingPathComponent(
                "replacement.caf"
            )
            try writeCAF(
                samples: Array(repeating: 0.1, count: 4_800),
                to: replacement
            )
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)

            await assertReaderError(
                sequence,
                equals: .segmentIdentityChanged(index: 0)
            )
        }

        for (format, frameCount, expectedError) in [
            (
                MeetingTrackAudioSegmentFormat(
                    sampleRate: 44_100,
                    channelCount: 1,
                    isFloat32: true
                ),
                Int64(4_800),
                MeetingTrackAudioReaderError
                    .reopenedSegmentFormatMismatch(index: 0)
            ),
            (
                MeetingTrackAudioSegmentFormat(
                    sampleRate: 48_000,
                    channelCount: 1,
                    isFloat32: true
                ),
                Int64(4_799),
                MeetingTrackAudioReaderError
                    .reopenedSegmentFrameCountMismatch(
                        index: 0,
                        expected: 4_800,
                        actual: 4_799
                    )
            ),
        ] {
            let fixture = try await makeSingleSegmentFixture()
            let segmentReader = FakeTrackSegmentReader(
                format: format,
                declaredFrameCount: frameCount,
                reads: []
            )
            let reader = MeetingTrackAudioReader(
                sourceLoader: MeetingAudioSourceLoader(
                    fileStore: fixture.fileStore
                ),
                segmentReaderFactory: FakeTrackSegmentReaderFactory(
                    readers: [segmentReader]
                )
            )

            await assertReaderError(
                try await reader.chunks(
                    meetingID: fixture.meetingID,
                    track: .microphone
                ),
                equals: expectedError
            )
        }
    }

    func testShortOrZeroReadBeforeDeclaredFramesThrowsTypedError()
        async throws {
        for actualCount in [2_399, 0] {
            let fixture = try await makeSingleSegmentFixture()
            let segmentReader = FakeTrackSegmentReader(
                format: .init(
                    sampleRate: 48_000,
                    channelCount: 1,
                    isFloat32: true
                ),
                declaredFrameCount: 4_800,
                reads: [Array(repeating: 0.25, count: actualCount)]
            )
            let reader = MeetingTrackAudioReader(
                sourceLoader: MeetingAudioSourceLoader(
                    fileStore: fixture.fileStore
                ),
                segmentReaderFactory: FakeTrackSegmentReaderFactory(
                    readers: [segmentReader]
                )
            )

            await assertReaderError(
                try await reader.chunks(
                    meetingID: fixture.meetingID,
                    track: .microphone
                ),
                equals: .shortRead(
                    index: 0,
                    expected: 4_800,
                    actual: actualCount
                )
            )
        }
    }

    func testSampleChunksAreSinglePass() async throws {
        let sequence = MeetingAudioSampleChunks([
            MeetingAudioSampleChunk(samples: [1], startingAt: 0),
        ])
        var first = sequence.makeAsyncIterator()
        var second = sequence.makeAsyncIterator()

        let firstChunk = try await first.next()
        XCTAssertEqual(
            firstChunk,
            MeetingAudioSampleChunk(samples: [1], startingAt: 0)
        )
        do {
            _ = try await second.next()
            XCTFail("Expected the second iterator to be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingTrackAudioReaderError,
                .multipleIterators
            )
        }
    }

    func testCancellationClosesOpenSegment() async throws {
        let fixture = try await makeSingleSegmentFixture()
        let segmentReader = FakeTrackSegmentReader(
            format: .init(
                sampleRate: 48_000,
                channelCount: 1,
                isFloat32: true
            ),
            declaredFrameCount: 4_800,
            reads: [Array(repeating: 0.25, count: 4_800)]
        )
        let reader = MeetingTrackAudioReader(
            sourceLoader: MeetingAudioSourceLoader(
                fileStore: fixture.fileStore
            ),
            segmentReaderFactory: FakeTrackSegmentReaderFactory(
                readers: [segmentReader]
            )
        )
        let sequence = try await reader.chunks(
            meetingID: fixture.meetingID,
            track: .microphone
        )

        let task = Task {
            var iterator = sequence.makeAsyncIterator()
            _ = try await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            return try await iterator.next()
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        for _ in 0..<100 where !segmentReader.isClosed() {
            await Task.yield()
        }
        XCTAssertTrue(segmentReader.isClosed())
    }

    private func makeTwoSegmentFixture() async throws -> ReaderFixture {
        let fixture = try makeReaderFixture()
        let writer = try SegmentedPCMWriter(
            meetingID: fixture.meetingID,
            fileStore: fixture.fileStore,
            track: .microphone,
            frameLimit: 4_800,
            sampleRate: 48_000
        )
        try await writer.append(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: 48_000,
                samples: Array(repeating: 0.25, count: 9_600)
            )
        )
        _ = try await writer.finish()
        return fixture
    }

    private func makeSingleSegmentFixture() async throws -> ReaderFixture {
        let fixture = try makeReaderFixture()
        let writer = try SegmentedPCMWriter(
            meetingID: fixture.meetingID,
            fileStore: fixture.fileStore,
            track: .microphone,
            frameLimit: 4_800,
            sampleRate: 48_000
        )
        try await writer.append(
            CapturedAudioFrame(
                timestamp: 0,
                sampleRate: 48_000,
                samples: Array(repeating: 0.25, count: 4_800)
            )
        )
        _ = try await writer.finish()
        return fixture
    }

    private func makeReaderFixture() throws -> ReaderFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeetingTrackAudioReaderAdversarial-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ReaderFixture(
            root: root,
            fileStore: MeetingFileStore(rootURL: root),
            meetingID: UUID()
        )
    }

    private func collect(
        _ sequence: MeetingAudioSampleChunks
    ) async throws -> [MeetingAudioSampleChunk] {
        var chunks: [MeetingAudioSampleChunk] = []
        for try await chunk in sequence {
            chunks.append(chunk)
        }
        return chunks
    }

    private func assertReaderError(
        _ expression: @autoclosure () async throws
            -> MeetingAudioSampleChunks,
        equals expected: MeetingTrackAudioReaderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let sequence = try await expression()
            for try await _ in sequence {}
            XCTFail("Expected reader error", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MeetingTrackAudioReaderError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func writeCAF(samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
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
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
        file.close()
    }
}

private struct ReaderFixture {
    let root: URL
    let fileStore: MeetingFileStore
    let meetingID: UUID
}

private final class FakeTrackSegmentReader:
    MeetingTrackAudioSegmentReading,
    @unchecked Sendable {
    let format: MeetingTrackAudioSegmentFormat
    let declaredFrameCount: Int64

    private let lock = NSLock()
    private var reads: [[Float]]
    private var closed = false

    init(
        format: MeetingTrackAudioSegmentFormat,
        declaredFrameCount: Int64,
        reads: [[Float]]
    ) {
        self.format = format
        self.declaredFrameCount = declaredFrameCount
        self.reads = reads
    }

    func read(maximumFrameCount: Int) throws -> [Float] {
        lock.withLock {
            guard !reads.isEmpty else {
                return []
            }
            return reads.removeFirst()
        }
    }

    func close() {
        lock.withLock {
            closed = true
        }
    }

    func isClosed() -> Bool {
        lock.withLock { closed }
    }
}

private final class FakeTrackSegmentReaderFactory:
    MeetingTrackAudioSegmentReaderFactory,
    @unchecked Sendable {
    private let lock = NSLock()
    private var readers: [FakeTrackSegmentReader]

    init(readers: [FakeTrackSegmentReader]) {
        self.readers = readers
    }

    func open(url: URL) throws -> any MeetingTrackAudioSegmentReading {
        _ = url
        return lock.withLock {
            readers.removeFirst()
        }
    }
}

private final class ScriptedTrackPCMConverter:
    MeetingTrackPCMStreamingConverting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSegmentScripts: [[MeetingPCMConversionPull]]
    private var currentScript: [MeetingPCMConversionPull] = []
    private var appendedCounts: [Int] = []
    private var finishCalls = 0
    private var resetCalls = 0

    init(segmentScripts: [[MeetingPCMConversionPull]]) {
        remainingSegmentScripts = segmentScripts
    }

    func begin(inputSampleRate: Double) throws {
        _ = inputSampleRate
        lock.withLock {
            currentScript = remainingSegmentScripts.removeFirst()
        }
    }

    func append(samples: [Float]) throws {
        lock.withLock {
            appendedCounts.append(samples.count)
        }
    }

    func finishInput() {
        lock.withLock {
            finishCalls += 1
        }
    }

    func pull(maximumOutputSampleCount: Int) throws
        -> MeetingPCMConversionPull {
        _ = maximumOutputSampleCount
        return lock.withLock {
            currentScript.removeFirst()
        }
    }

    func reset() {
        lock.withLock {
            resetCalls += 1
        }
    }

    func appendedSampleCounts() -> [Int] {
        lock.withLock { appendedCounts }
    }

    func finishInputCallCount() -> Int {
        lock.withLock { finishCalls }
    }

    func resetCallCount() -> Int {
        lock.withLock { resetCalls }
    }
}
