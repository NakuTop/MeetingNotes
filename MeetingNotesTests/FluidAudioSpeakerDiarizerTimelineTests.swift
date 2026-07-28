import XCTest
@testable import MeetingNotes

final class FluidAudioSpeakerDiarizerTimelineTests:
    DiarizationAdapterTestCase {
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

        await assertInferenceFailure {
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

        await assertInferenceFailure {
            try await diarizer.diarize(source: source)
        }

        let confirmations = await sourceLoader.confirmations()
        let outputURLs = await converter.recordedOutputURLs()
        let counts = await engine.counts()
        XCTAssertEqual(confirmations, 2)
        XCTAssertTrue(outputURLs.isEmpty)
        XCTAssertEqual(counts.process, 0)
    }
}
