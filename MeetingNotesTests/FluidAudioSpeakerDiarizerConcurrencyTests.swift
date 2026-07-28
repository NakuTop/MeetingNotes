import XCTest
@testable import MeetingNotes

final class FluidAudioSpeakerDiarizerConcurrencyTests:
    DiarizationAdapterTestCase {
    func testConcurrentDifferentSourcesSerializeAndKeepDistinctResults()
        async throws {
        let root = try makeTemporaryRoot()
        let firstSource = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let secondSource = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.75, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let loader = DiarizationAdapterTestSourceLoader(
            source: firstSource
        )
        let engine = DiarizationAdapterBlockingEngine()
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: loader,
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )

        let first = Task {
            try await diarizer.diarize(source: firstSource)
        }
        await engine.waitUntilStarted(1)
        let second = Task {
            try await diarizer.diarize(source: secondSource)
        }
        let secondStartedPrematurely = try await didStart(
            engine,
            count: 2,
            within: .milliseconds(200)
        )

        let blockedSnapshot = await engine.snapshot()
        XCTAssertFalse(secondStartedPrematurely)
        XCTAssertEqual(blockedSnapshot.started, 1)
        XCTAssertEqual(blockedSnapshot.maximumActive, 1)

        await engine.releaseAllProcesses()
        let firstResult = try await first.value
        let secondResult = try await second.value
        let finalSnapshot = await engine.snapshot()
        XCTAssertEqual(
            firstResult.map { $0.rawSpeakerID },
            ["source-0.25"]
        )
        XCTAssertEqual(
            secondResult.map { $0.rawSpeakerID },
            ["source-0.75"]
        )
        XCTAssertEqual(finalSnapshot.prepare, 1)
        XCTAssertEqual(finalSnapshot.maximumActive, 1)
    }

    func testCancelledWaiterDoesNotDeadlockNextFIFOOperation()
        async throws {
        let root = try makeTemporaryRoot()
        let firstSource = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let cancelledSource = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.50, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let finalSource = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.75, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let engine = DiarizationAdapterBlockingEngine()
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: firstSource
            ),
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )

        let first = Task {
            try await diarizer.diarize(source: firstSource)
        }
        await engine.waitUntilStarted(1)
        let cancelled = Task {
            try await diarizer.diarize(source: cancelledSource)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        cancelled.cancel()
        let final = Task {
            try await diarizer.diarize(source: finalSource)
        }
        let laterOperationStartedPrematurely = try await didStart(
            engine,
            count: 2,
            within: .milliseconds(200)
        )

        let blockedSnapshot = await engine.snapshot()
        XCTAssertFalse(laterOperationStartedPrematurely)
        XCTAssertEqual(blockedSnapshot.started, 1)
        XCTAssertEqual(blockedSnapshot.maximumActive, 1)

        await engine.releaseAllProcesses()
        _ = try await first.value
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancelled waiter")
        } catch is CancellationError {
            // Expected.
        }
        let finalResult = try await final.value
        let finalSnapshot = await engine.snapshot()
        XCTAssertEqual(
            finalResult.map { $0.rawSpeakerID },
            ["source-0.75"]
        )
        XCTAssertEqual(finalSnapshot.started, 2)
        XCTAssertEqual(finalSnapshot.maximumActive, 1)
    }

    func testConcurrentCallsPrepareModelsOnlyOnce() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(
            root: root,
            segmentSamples: [
                Array(repeating: 0.25, count: 4_800),
            ],
            segmentStartTimes: [0]
        )
        let engine = DiarizationAdapterPreparationEngine()
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )

        let first = Task {
            try await diarizer.diarize(source: source)
        }
        await engine.waitUntilPreparationStarted(1)
        let second = Task {
            try await diarizer.diarize(source: source)
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        let blockedPreparationCount = await engine.count()
        XCTAssertEqual(blockedPreparationCount, 1)
        await engine.releaseAllPreparations()
        _ = try await first.value
        _ = try await second.value
        let finalPreparationCount = await engine.count()
        XCTAssertEqual(finalPreparationCount, 1)
    }

    func testFailedPreparationRetriesOnNextOperation() async throws {
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
                    rawSpeakerID: "retry",
                    startTime: 0,
                    endTime: 0.05
                ),
            ]],
            preparationFailures: 1
        )
        let diarizer = makeDiarizer(
            root: root,
            sourceLoader: DiarizationAdapterTestSourceLoader(
                source: source
            ),
            engine: engine,
            converter: DiarizationAdapterTestConverter()
        )

        do {
            _ = try await diarizer.diarize(source: source)
            XCTFail("Expected first preparation to fail")
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationError,
                .modelPreparationFailed
            )
        }
        let retry = try await diarizer.diarize(source: source)

        XCTAssertEqual(
            retry.map { $0.rawSpeakerID },
            ["retry"]
        )
        let counts = await engine.counts()
        XCTAssertEqual(counts.prepare, 2)
        XCTAssertEqual(counts.process, 1)
    }

    private func didStart(
        _ engine: DiarizationAdapterBlockingEngine,
        count: Int,
        within timeout: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await engine.snapshot().started >= count {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await engine.snapshot().started >= count
    }
}
