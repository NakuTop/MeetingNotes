import XCTest
@testable import MeetingNotes

final class AudioSignalMetricsTests: XCTestCase {
    func testEmptyAccumulatorReportsNoFrames() {
        let metrics = AudioSignalAccumulator().snapshot()

        XCTAssertEqual(metrics.sampleCount, 0)
        XCTAssertEqual(metrics.rms, 0)
        XCTAssertEqual(metrics.peak, 0)
        XCTAssertEqual(metrics.observationDuration, 0)
        XCTAssertEqual(metrics.sampleRate, 0)
        XCTAssertEqual(metrics.channelCount, 0)
        XCTAssertEqual(metrics.level, .noFrames)
    }

    func testAccumulatorComputesSampleCountRMSPeakAndDuration() {
        var accumulator = AudioSignalAccumulator()
        accumulator.ingest(
            samples: [0.5, -0.5, 0, 0],
            sampleRate: 4,
            channelCount: 1
        )

        let metrics = accumulator.snapshot()

        XCTAssertEqual(metrics.sampleCount, 4)
        XCTAssertEqual(metrics.rms, sqrt(0.125), accuracy: 0.000_001)
        XCTAssertEqual(metrics.peak, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(metrics.observationDuration, 1, accuracy: 0.000_001)
        XCTAssertEqual(metrics.sampleRate, 4)
        XCTAssertEqual(metrics.channelCount, 1)
        XCTAssertEqual(metrics.level, .audible)
    }

    func testAccumulatorCombinesMultipleIngestionsAndTheirDurations() {
        var accumulator = AudioSignalAccumulator()
        accumulator.ingest(
            samples: [0.5, -0.5, 0, 0],
            sampleRate: 4,
            channelCount: 1
        )
        accumulator.ingest(
            samples: [1, 0, 0, 0],
            sampleRate: 2,
            channelCount: 2
        )

        let metrics = accumulator.snapshot()

        XCTAssertEqual(metrics.sampleCount, 8)
        XCTAssertEqual(metrics.rms, sqrt(1.5 / 8), accuracy: 0.000_001)
        XCTAssertEqual(metrics.peak, 1, accuracy: 0.000_001)
        XCTAssertEqual(metrics.observationDuration, 2, accuracy: 0.000_001)
        XCTAssertEqual(metrics.sampleRate, 2)
        XCTAssertEqual(metrics.channelCount, 2)
    }

    func testNonFiniteSamplesAreCountedAsZeroAndNeverProduceNonFiniteMetrics() {
        var accumulator = AudioSignalAccumulator()
        accumulator.ingest(
            samples: [.nan, .infinity, -.infinity, 0.5],
            sampleRate: 4,
            channelCount: 1
        )

        let metrics = accumulator.snapshot()

        XCTAssertEqual(metrics.sampleCount, 4)
        XCTAssertEqual(metrics.rms, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(metrics.peak, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(metrics.rms.isFinite)
        XCTAssertTrue(metrics.peak.isFinite)
    }

    func testInvalidMetadataBatchIsIgnoredAndDoesNotReplaceValidMetadata() {
        var accumulator = AudioSignalAccumulator()
        accumulator.ingest(
            samples: [0.25, -0.25],
            sampleRate: 2,
            channelCount: 1
        )
        accumulator.ingest(
            samples: [0.25, -0.25],
            sampleRate: 0,
            channelCount: -1
        )

        let metrics = accumulator.snapshot()

        XCTAssertEqual(metrics.sampleCount, 2)
        XCTAssertEqual(metrics.rms, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(metrics.peak, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(metrics.observationDuration, 1, accuracy: 0.000_001)
        XCTAssertEqual(metrics.sampleRate, 2)
        XCTAssertEqual(metrics.channelCount, 1)
        XCTAssertTrue(metrics.observationDuration.isFinite)
    }

    func testOnlyInvalidMetadataBatchesLeaveAccumulatorEmpty() {
        var accumulator = AudioSignalAccumulator()
        accumulator.ingest(
            samples: [0.5, -0.5],
            sampleRate: 0,
            channelCount: 1
        )
        accumulator.ingest(
            samples: [0.75],
            sampleRate: -48_000,
            channelCount: 1
        )
        accumulator.ingest(
            samples: [1],
            sampleRate: 48_000,
            channelCount: 0
        )

        let metrics = accumulator.snapshot()

        XCTAssertEqual(metrics.sampleCount, 0)
        XCTAssertEqual(metrics.rms, 0)
        XCTAssertEqual(metrics.peak, 0)
        XCTAssertEqual(metrics.observationDuration, 0)
        XCTAssertEqual(metrics.sampleRate, 0)
        XCTAssertEqual(metrics.channelCount, 0)
        XCTAssertEqual(metrics.level, .noFrames)
    }

    func testLevelThresholdsAreStableAtTheirBoundaries() {
        let cases: [(samples: [Float], expected: AudioLevelBand)] = [
            ([0], .silent),
            ([0.000_009], .silent),
            ([0.000_01], .veryLow),
            ([0.002_999], .veryLow),
            ([0.003], .audible)
        ]

        for testCase in cases {
            var accumulator = AudioSignalAccumulator()
            accumulator.ingest(
                samples: testCase.samples,
                sampleRate: 1,
                channelCount: 1
            )

            XCTAssertEqual(
                accumulator.snapshot().level,
                testCase.expected,
                "samples: \(testCase.samples)"
            )
        }
    }
}
