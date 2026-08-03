import XCTest
@testable import MeetingNotes

final class FluidAudioSpeakerDiarizerTimelineTests:
    DiarizationAdapterTestCase {
    func testContinuesReadingAfterPositivePartialBuffer() throws {
        var progress = try DiarizationSegmentReadProgress(
            expectedFrames: 10
        )

        let firstDecision = try progress.recordRead(
            requestedFrames: 10,
            decodedFrames: 4
        )

        XCTAssertEqual(firstDecision, .continueReading)
        XCTAssertEqual(progress.framesRead, 4)
        XCTAssertEqual(progress.remainingFrames, 6)

        let secondDecision = try progress.recordRead(
            requestedFrames: 6,
            decodedFrames: 6
        )

        XCTAssertEqual(secondDecision, .complete)
        XCTAssertEqual(progress.framesRead, 10)
        XCTAssertEqual(
            try progress.paddingFrames(maximum: 1_024),
            0
        )
    }

    func testPadsBoundedCAFTailShortReadWithSilence() async throws {
        let root = try makeTemporaryRoot()
        let physicalFrameCount = 719_872
        let declaredFrameCount: Int64 = 720_000
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: physicalFrameCount),
            ],
            segmentStartTimes: [0],
            declaredFrameCounts: [declaredFrameCount]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        _ = try await diarizer.diarize(source: source)

        let recordedInputs = await converter.recordedInputSamples()
        let captured = try XCTUnwrap(recordedInputs.first)
        XCTAssertEqual(captured.count, Int(declaredFrameCount))
        XCTAssertEqual(
            captured[physicalFrameCount - 1],
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Array(captured[physicalFrameCount..<Int(declaredFrameCount)]),
            Array(repeating: 0, count: 128)
        )
    }

    func testRejectsSegmentWhenCAFDecodesNoFrames() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[]],
            segmentStartTimes: [0],
            declaredFrameCounts: [1]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.timelineAssemblyFailed) {
            try await diarizer.diarize(source: source)
        }

        let recordedInputs = await converter.recordedInputSamples()
        let counts = await engine.counts()
        XCTAssertTrue(recordedInputs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testRejectsCAFTailShortfallAboveSafetyBound() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0],
            declaredFrameCounts: [1_026]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.timelineAssemblyFailed) {
            try await diarizer.diarize(source: source)
        }

        let recordedInputs = await converter.recordedInputSamples()
        let counts = await engine.counts()
        XCTAssertTrue(recordedInputs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testPadsCAFTailShortfallAtSafetyBound() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0],
            declaredFrameCounts: [1_025]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        _ = try await diarizer.diarize(source: source)

        let recordedInputs = await converter.recordedInputSamples()
        let captured = try XCTUnwrap(recordedInputs.first)
        XCTAssertEqual(captured.count, 1_025)
        XCTAssertEqual(captured[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(
            Array(captured[1..<1_025]),
            Array(repeating: 0, count: 1_024)
        )
    }

    func testGappedSegmentsInsertSilenceAndKeepPostGapSpeakerTiming()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
                Array(repeating: 0.75, count: 4_800),
            ],
            segmentStartTimes: [0, 0.2]
        )
        let sourceLoader = DiarizationAdapterTestSourceLoader(
            source: source
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(
            results: [[
                SpeakerInterval(
                    rawSpeakerID: "post-gap",
                    startTime: 0.2,
                    endTime: 0.3
                ),
            ]]
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: sourceLoader,
            engine: engine,
            converter: converter
        )

        let intervals = try await diarizer.diarize(source: source)

        let recordedInputs = await converter.recordedInputSamples()
        let captured = try XCTUnwrap(
            recordedInputs.first
        )
        XCTAssertEqual(captured.count, 14_400)
        XCTAssertEqual(captured[4_799], 0.25, accuracy: 0.001)
        XCTAssertEqual(
            Array(captured[4_800..<9_600]),
            Array(repeating: 0, count: 4_800)
        )
        XCTAssertEqual(captured[9_600], 0.75, accuracy: 0.001)
        let processedSampleCounts = await engine.sampleCounts()
        XCTAssertEqual(processedSampleCounts, [4_800])

        let assigned = SpeakerIntervalAssigner().assign(
            [
                TranscriptDraft(
                    startTime: 0.21,
                    endTime: 0.29,
                    text: "间隔后的说话"
                ),
            ],
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )
        XCTAssertEqual(
            assigned.map { $0.speakerID },
            ["remote-1"]
        )
    }

    func testRejectsMismatchedSegmentMetadataBeforeConversion()
        async throws {
        let root = try makeTemporaryRoot()
        let valid = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
                Array(repeating: 0.75, count: 4_800),
            ],
            segmentStartTimes: [0, 0.1]
        )
        let malformed = MeetingAudioSource(
            meetingID: valid.meetingID,
            resolvedSegments: valid.resolvedSegments,
            segmentFrameCounts: valid.segmentFrameCounts,
            sampleRate: valid.sampleRate,
            channelCount: valid.channelCount,
            totalFrames: valid.totalFrames,
            manifestSignature: valid.manifestSignature,
            identitySignature: valid.identitySignature,
            segmentStartTimes: [0]
        )
        let sourceLoader = DiarizationAdapterTestSourceLoader(
            source: malformed
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: sourceLoader,
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: malformed)
        }

        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testRejectsIdentityChangeReportedImmediatelyAfterOpen()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let sourceLoader = DiarizationAdapterTestSourceLoader(
            source: source,
            failingConfirmation: 2
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: sourceLoader,
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: source)
        }

        let confirmations = await sourceLoader.confirmations()
        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertEqual(confirmations, 2)
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testRejectsInt64MaximumStartTimeBeforeConversion()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [Double(Int64.max)]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: source)
        }

        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testRejectsFiniteGapAboveTwoHoursBeforeConversion()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [
                2 * 60 * 60 + 1.0 / 48_000,
            ]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: source)
        }

        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testRejectsSegmentEndBeyondInjectedTimelineLimit()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 5),
            ],
            segmentStartTimes: [2.0 / 48_000]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter,
            timelineLimits: DiarizationTimelineLimits(
                maximumTimelineFrames: 6,
                maximumSingleGapFrames: 2,
                maximumTimelineByteCount: 24
            )
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: source)
        }

        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }

    func testAcceptsExactInjectedGapTimelineAndByteBoundaries()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 3),
                Array(repeating: 0.75, count: 3),
            ],
            segmentStartTimes: [0, 7.0 / 48_000]
        )
        let converter = DiarizationAdapterTestConverter()
        let engine = DiarizationAdapterImmediateEngine(results: [[]])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: converter,
            timelineLimits: DiarizationTimelineLimits(
                maximumTimelineFrames: 10,
                maximumSingleGapFrames: 4,
                maximumTimelineByteCount: 40
            )
        )

        let intervals = try await diarizer.diarize(source: source)

        let recordedInputs = await converter.recordedInputSamples()
        let captured = try XCTUnwrap(recordedInputs.first)
        let counts = await engine.counts()
        XCTAssertTrue(intervals.isEmpty)
        XCTAssertEqual(captured.count, 10)
        XCTAssertEqual(
            Array(captured[3..<7]),
            Array(repeating: 0, count: 4)
        )
        XCTAssertEqual(counts.process, 1)
    }
}
