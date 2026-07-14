import XCTest
@testable import MeetingNotes

final class TranscriptionQueueTests: XCTestCase {
    func testProcessesChunksInOrderAndDrainWaitsForCompletion() async throws {
        let service = RecordingTranscriptionService()
        let queue = TranscriptionQueue(service: service)

        await queue.enqueue(samples: [0], startingAt: 0)
        await queue.enqueue(samples: [1], startingAt: 15)
        await queue.enqueue(samples: [2], startingAt: 30)
        await queue.drain()

        let starts = await service.transcribedStarts()
        let transcripts = await queue.transcripts()
        let snapshot = await queue.snapshot()
        XCTAssertEqual(starts, [0, 15, 30])
        XCTAssertEqual(transcripts.map(\.startTime), [0, 15, 30])
        XCTAssertEqual(snapshot, .idle)
    }

    func testEnqueueReturnsWhileSingleConsumerIsStillTranscribing() async throws {
        let service = SuspendedTranscriptionService()
        let queue = TranscriptionQueue(service: service)

        await queue.enqueue(samples: [0.5], startingAt: 4)

        for _ in 0..<100 {
            if await service.hasStarted() {
                break
            }
            await Task.yield()
        }
        let started = await service.hasStarted()
        let processingSnapshot = await queue.snapshot()
        XCTAssertTrue(started)
        XCTAssertEqual(
            processingSnapshot,
            .init(waitingCount: 0, isProcessing: true, failedCount: 0)
        )

        await service.resume()
        await queue.drain()
        let transcriptTexts = await queue.transcripts().map(\.text)
        XCTAssertEqual(transcriptTexts, ["4"])
    }

    func testFailedChunkCanBeRequeuedWithoutOverlappingInference() async throws {
        let service = FailOnceTranscriptionService(failingStart: 15)
        let queue = TranscriptionQueue(service: service)

        await queue.enqueue(samples: [0], startingAt: 0)
        await queue.enqueue(samples: [1], startingAt: 15)
        await queue.enqueue(samples: [2], startingAt: 30)
        await queue.drain()

        let failedSnapshot = await queue.snapshot()
        XCTAssertEqual(
            failedSnapshot,
            .init(waitingCount: 0, isProcessing: false, failedCount: 1)
        )
        await queue.retryFailed()
        await queue.drain()

        let starts = await service.transcribedStarts()
        let maximumCalls = await service.maximumConcurrentCalls()
        let transcriptStarts = await queue.transcripts().map(\.startTime)
        let idleSnapshot = await queue.snapshot()
        XCTAssertEqual(starts, [0, 15, 30, 15])
        XCTAssertEqual(maximumCalls, 1)
        XCTAssertEqual(transcriptStarts, [0, 15, 30])
        XCTAssertEqual(idleSnapshot, .idle)
    }
}

private actor RecordingTranscriptionService: TranscriptionService {
    private var starts: [TimeInterval] = []

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        starts.append(startingAt)
        return [
            TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + 1,
                text: "\(Int(startingAt))"
            )
        ]
    }

    func transcribedStarts() -> [TimeInterval] {
        starts
    }
}

private actor SuspendedTranscriptionService: TranscriptionService {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return [
            TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + 1,
                text: "\(Int(startingAt))"
            )
        ]
    }

    func hasStarted() -> Bool {
        started
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum FakeTranscriptionError: Error {
    case expectedFailure
}

private actor FailOnceTranscriptionService: TranscriptionService {
    private let failingStart: TimeInterval
    private var hasFailed = false
    private var starts: [TimeInterval] = []
    private var activeCalls = 0
    private var maximumCalls = 0

    init(failingStart: TimeInterval) {
        self.failingStart = failingStart
    }

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        starts.append(startingAt)
        activeCalls += 1
        maximumCalls = max(maximumCalls, activeCalls)
        defer { activeCalls -= 1 }

        if startingAt == failingStart, !hasFailed {
            hasFailed = true
            throw FakeTranscriptionError.expectedFailure
        }
        return [
            TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + 1,
                text: "\(Int(startingAt))"
            )
        ]
    }

    func transcribedStarts() -> [TimeInterval] {
        starts
    }

    func maximumConcurrentCalls() -> Int {
        maximumCalls
    }
}
