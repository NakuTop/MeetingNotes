import XCTest
@testable import MeetingNotes

final class FluidAudioSpeakerDiarizerResourceTests:
    DiarizationAdapterTestCase {
    func testRejectsInvalidIntervalsAtAdapterBoundary() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let invalidIntervals = [
            SpeakerInterval(
                rawSpeakerID: " ",
                startTime: 0,
                endTime: 0.05
            ),
            SpeakerInterval(
                rawSpeakerID: "nan-start",
                startTime: .nan,
                endTime: 0.05
            ),
            SpeakerInterval(
                rawSpeakerID: "nan-end",
                startTime: 0,
                endTime: .nan
            ),
            SpeakerInterval(
                rawSpeakerID: "negative",
                startTime: -0.01,
                endTime: 0.05
            ),
            SpeakerInterval(
                rawSpeakerID: "empty-range",
                startTime: 0.05,
                endTime: 0.05
            ),
            SpeakerInterval(
                rawSpeakerID: "past-end",
                startTime: 0.05,
                endTime: 0.1 + 1.0 / 16_000 + 0.000_001
            ),
        ]

        for interval in invalidIntervals {
            let loader = DiarizationAdapterTestSourceLoader(
                source: source
            )
            let engine = DiarizationAdapterImmediateEngine(
                results: [[interval]]
            )
            let diarizer = makeDiarizer(
                root: root,
                sourceLoader: loader,
                engine: engine,
                converter: DiarizationAdapterTestConverter()
            )

            await assertInferenceFailure {
                try await diarizer.diarize(source: source)
            }
        }
    }

    func testTrimsValidSpeakerIDsAndPreservesOverlappingIntervals()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let engine = DiarizationAdapterImmediateEngine(
            results: [[
                SpeakerInterval(
                    rawSpeakerID: " alpha ",
                    startTime: 0,
                    endTime: 0.08
                ),
                SpeakerInterval(
                    rawSpeakerID: "beta",
                    startTime: 0.04,
                    endTime: 0.1 + 1.0 / 16_000
                ),
            ]]
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )

        let intervals = try await diarizer.diarize(source: source)

        XCTAssertEqual(
            intervals,
            [
                SpeakerInterval(
                    rawSpeakerID: "alpha",
                    startTime: 0,
                    endTime: 0.08
                ),
                SpeakerInterval(
                    rawSpeakerID: "beta",
                    startTime: 0.04,
                    endTime: 0.1 + 1.0 / 16_000
                ),
            ]
        )
    }

    func testConversionFailureDeletesRawAndTimelineTemporaryFiles()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let converter = DiarizationAdapterTestConverter(
            behavior: .failAfterWriting
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: DiarizationAdapterImmediateEngine(results: [[]]),
            converter: converter
        )

        await assertInferenceFailure {
            try await diarizer.diarize(source: source)
        }

        let outputURLs = await converter.recordedOutputURLs()
        let outputURL = try XCTUnwrap(outputURLs.first)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path)
        )
        XCTAssertTrue(
            try temporaryArtifacts(in: root).isEmpty
        )
    }

    func testCancellationDeletesRawAndTimelineTemporaryFiles()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let engine = DiarizationAdapterCancellableEngine()
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )
        let task = Task {
            try await diarizer.diarize(source: source)
        }
        await engine.waitUntilStarted()
        let processedURL = await engine.sourceURL()
        let rawURL = try XCTUnwrap(processedURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawURL.path)
        )

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rawURL.path)
        )
        XCTAssertTrue(
            try temporaryArtifacts(in: root).isEmpty
        )
    }

    private func temporaryArtifacts(
        in root: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                "meeting-notes-diarization-"
            )
                || $0.lastPathComponent.hasPrefix(
                    "meeting-notes-fluidaudio-"
                )
        }
    }
}
