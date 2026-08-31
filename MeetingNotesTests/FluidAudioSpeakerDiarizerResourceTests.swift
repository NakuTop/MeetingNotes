import XCTest
@testable import MeetingNotes

final class FluidAudioSpeakerDiarizerResourceTests:
    DiarizationAdapterTestCase {
    func testProductionOfflineDiarizerUsesVerifiedClusteringThreshold() {
        let config = OfflineFluidAudioDiarizationEngine.productionConfig

        XCTAssertEqual(
            config.clustering.threshold,
            0.7045655,
            accuracy: 0.0000001
        )
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
        XCTAssertNil(config.clustering.numSpeakers)
    }

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
                endTime: 0.201
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

            await assertDiarizationFailure(.resultValidationFailed) {
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
                    endTime: 0.09
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
                    endTime: 0.09
                ),
            ]
        )
    }

    func testClampsFiftyMillisecondModelFrameOvershootToTimelineEnd()
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
                    rawSpeakerID: "speaker",
                    startTime: 0.05,
                    endTime: 0.15
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
                    rawSpeakerID: "speaker",
                    startTime: 0.05,
                    endTime: 0.1
                ),
            ]
        )
    }

    func testRejectsOneHundredOneMillisecondOvershoot()
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
                    rawSpeakerID: "speaker",
                    startTime: 0.05,
                    endTime: 0.201
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

        await assertDiarizationFailure(.resultValidationFailed) {
            try await diarizer.diarize(source: source)
        }
    }

    func testKeepsExactTimelineEndUnchanged() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let exact = SpeakerInterval(
            rawSpeakerID: "speaker",
            startTime: 0,
            endTime: 0.1
        )
        let engine = DiarizationAdapterImmediateEngine(
            results: [[exact]]
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

        XCTAssertEqual(intervals, [exact])
    }

    func testRejectsRangeMadeInvalidByTimelineClamp()
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
                    rawSpeakerID: "speaker",
                    startTime: 0.11,
                    endTime: 0.15
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

        await assertDiarizationFailure(.resultValidationFailed) {
            try await diarizer.diarize(source: source)
        }
    }

    func testMapsInvalidManifestToInvalidSource() async throws {
        let root = try makeTemporaryRoot()
        let valid = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0]
        )
        let malformed = MeetingAudioSource(
            meetingID: valid.meetingID,
            resolvedSegments: valid.resolvedSegments,
            segmentFrameCounts: [],
            sampleRate: valid.sampleRate,
            channelCount: valid.channelCount,
            totalFrames: valid.totalFrames,
            manifestSignature: valid.manifestSignature,
            identitySignature: valid.identitySignature,
            segmentStartTimes: valid.segmentStartTimes
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: malformed
            ),
            engine: DiarizationAdapterImmediateEngine(results: [[]]),
            converter: DiarizationAdapterTestConverter()
        )

        await assertDiarizationFailure(.invalidSource) {
            try await diarizer.diarize(source: malformed)
        }
    }

    func testMapsTimelineReadFailureToTimelineAssemblyFailed()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0]
        )
        try FileManager.default.removeItem(at: source.segmentURLs[0])
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: DiarizationAdapterImmediateEngine(results: [[]]),
            converter: DiarizationAdapterTestConverter()
        )

        await assertDiarizationFailure(.timelineAssemblyFailed) {
            try await diarizer.diarize(source: source)
        }
    }

    func testMapsModelPreparationFailureToModelPreparationFailed()
        async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0]
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: DiarizationAdapterImmediateEngine(
                results: [[]],
                preparationFailures: 1
            ),
            converter: DiarizationAdapterTestConverter()
        )

        await assertDiarizationFailure(.modelPreparationFailed) {
            try await diarizer.diarize(source: source)
        }
    }

    func testMapsEngineProcessFailureToInferenceFailed() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [[0.25]],
            segmentStartTimes: [0]
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: DiarizationAdapterImmediateEngine(
                results: [],
                processError: DiarizationAdapterTestError.processing
            ),
            converter: DiarizationAdapterTestConverter()
        )

        await assertDiarizationFailure(.inferenceFailed) {
            try await diarizer.diarize(source: source)
        }
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

        await assertDiarizationFailure(.conversionFailed) {
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

    func testCancellationErrorIsPreservedAtEachAsyncStageBoundary()
        async throws {
        let stages: [(
            loader: (MeetingAudioSource) -> DiarizationAdapterTestSourceLoader,
            engine: DiarizationAdapterImmediateEngine,
            converter: DiarizationAdapterTestConverter
        )] = [
            (
                { DiarizationAdapterTestSourceLoader(source: $0) },
                DiarizationAdapterImmediateEngine(
                    results: [],
                    cancelPreparation: true
                ),
                DiarizationAdapterTestConverter()
            ),
            (
                {
                    DiarizationAdapterTestSourceLoader(
                        source: $0,
                        cancellingConfirmation: 1
                    )
                },
                DiarizationAdapterImmediateEngine(results: [[]]),
                DiarizationAdapterTestConverter()
            ),
            (
                { DiarizationAdapterTestSourceLoader(source: $0) },
                DiarizationAdapterImmediateEngine(results: [[]]),
                DiarizationAdapterTestConverter(
                    behavior: .cancelAfterWriting
                )
            ),
            (
                { DiarizationAdapterTestSourceLoader(source: $0) },
                DiarizationAdapterImmediateEngine(
                    results: [],
                    cancelProcessing: true
                ),
                DiarizationAdapterTestConverter()
            ),
        ]

        for stage in stages {
            let root = try makeTemporaryRoot()
            let source = try makeSource(
                root: root,
                segmentSamples: [[0.25]],
                segmentStartTimes: [0]
            )
            let diarizer = makeDiarizer(
                root: root,
                sourceLoader: stage.loader(source),
                engine: stage.engine,
                converter: stage.converter
            )

            do {
                _ = try await diarizer.diarize(source: source)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail(
                    "Expected CancellationError, received \(type(of: error))"
                )
            }
            XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
        }
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
