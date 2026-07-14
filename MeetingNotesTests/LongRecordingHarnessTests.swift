import Foundation
import XCTest
@testable import MeetingNotes

final class LongRecordingHarnessTests: XCTestCase {
    func testOneHourEquivalentCaptureKeepsWriterCompleteAndQueueBounded() async {
        let service = BlockingPreparationService()
        let queue = TranscriptionQueue(
            service: service,
            maximumBufferedChunks: 8
        )
        var writer = LogicalSampleWriter()

        writer.append(logicalSampleCount: 16_000)
        await queue.enqueue(samples: [0], startingAt: 0)
        await service.waitUntilPreparationStarts()

        let clock = ContinuousClock()
        let startedAt = clock.now
        for second in 1..<3_600 {
            writer.append(logicalSampleCount: 16_000)
            if second.isMultiple(of: 15) {
                await queue.enqueue(
                    samples: [0],
                    startingAt: TimeInterval(second)
                )
            }
        }
        let productionDuration = startedAt.duration(to: clock.now)
        let snapshot = await queue.snapshot()
        let deferredChunks = await queue.deferredChunks()

        XCTAssertEqual(writer.totalLogicalSamples, 3_600 * 16_000)
        XCTAssertLessThanOrEqual(snapshot.waitingCount, 8)
        XCTAssertGreaterThan(snapshot.deferredCount, 0)
        XCTAssertEqual(deferredChunks.count, snapshot.deferredCount)
        XCTAssertTrue(deferredChunks.allSatisfy { $0.sampleCount == 1 })
        XCTAssertLessThan(productionDuration, .seconds(2))

        await service.failPreparation()
        await queue.drain()
    }
}

private struct LogicalSampleWriter {
    private(set) var totalLogicalSamples = 0

    mutating func append(logicalSampleCount: Int) {
        totalLogicalSamples += logicalSampleCount
    }
}

private enum HarnessPreparationError: Error {
    case expectedFailure
}

private actor BlockingPreparationService: TranscriptionService {
    private var preparationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Error>?

    func prepare() async throws {
        preparationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        _ = samples
        _ = startingAt
        return []
    }

    func waitUntilPreparationStarts() async {
        if preparationStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func failPreparation() {
        finishContinuation?.resume(
            throwing: HarnessPreparationError.expectedFailure
        )
        finishContinuation = nil
    }
}
