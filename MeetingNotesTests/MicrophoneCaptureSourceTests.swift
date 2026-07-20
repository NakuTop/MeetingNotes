import XCTest
@testable import MeetingNotes

final class MicrophoneCaptureSourceTests: XCTestCase {
    func testFinishAndWaitDrainsAcceptedBuffersInStrictOrder() async {
        let gate = MicrophoneDrainTestGate()
        let recorder = MicrophoneDrainRecorder()
        let completion = MicrophoneDrainCompletion()
        let drain = MicrophoneCaptureDrainQueue<Int>(capacity: 3) { value in
            await recorder.markStarted(value)
            if value == 1 {
                await gate.wait()
            }
            await recorder.markCompleted(value)
        }

        XCTAssertTrue(drain.enqueue(1))
        XCTAssertTrue(drain.enqueue(2))
        XCTAssertTrue(drain.enqueue(3))
        await recorder.waitUntilStarted(1)

        let stopping = Task {
            await drain.finishAndWait()
            await completion.markCompleted()
        }
        await Task.yield()

        let completedBeforeOpening = await completion.isCompleted()
        XCTAssertFalse(completedBeforeOpening)
        await gate.open()
        await stopping.value

        let completedValues = await recorder.completedValues()
        XCTAssertEqual(completedValues, [1, 2, 3])
        XCTAssertFalse(drain.enqueue(4))
    }

    func testOverflowClosesInputAndDrainsAcceptedBuffersWithoutDeadlock() async {
        let gate = MicrophoneDrainTestGate()
        let recorder = MicrophoneDrainRecorder()
        let completion = MicrophoneDrainCompletion()
        let overflow = MicrophoneDrainOverflowRecorder()
        let drain = MicrophoneCaptureDrainQueue<Int>(
            capacity: 3,
            onOverflow: {
                overflow.record()
            },
            handler: { value in
                await recorder.markStarted(value)
                if value == 1 {
                    await gate.wait()
                }
                await recorder.markCompleted(value)
            }
        )

        XCTAssertTrue(drain.enqueue(1))
        await recorder.waitUntilStarted(1)
        XCTAssertTrue(drain.enqueue(2))
        XCTAssertTrue(drain.enqueue(3))
        XCTAssertFalse(drain.enqueue(4))
        XCTAssertFalse(drain.enqueue(5))

        let draining = Task {
            await drain.waitUntilDrained()
            await completion.markCompleted()
        }
        await Task.yield()
        let completedWhileBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileBlocked)

        await gate.open()
        await draining.value

        let completedValues = await recorder.completedValues()
        let overflowCount = overflow.count()
        XCTAssertEqual(completedValues, [1, 2, 3])
        XCTAssertEqual(overflowCount, 1)
    }
}

private actor MicrophoneDrainTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MicrophoneDrainRecorder {
    private var started: Set<Int> = []
    private var completed: [Int] = []
    private var startedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted(_ value: Int) {
        started.insert(value)
        startedWaiters.removeValue(forKey: value)?.forEach { $0.resume() }
    }

    func waitUntilStarted(_ value: Int) async {
        guard !started.contains(value) else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[value, default: []].append(continuation)
        }
    }

    func markCompleted(_ value: Int) {
        completed.append(value)
    }

    func completedValues() -> [Int] {
        completed
    }
}

private actor MicrophoneDrainCompletion {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class MicrophoneDrainOverflowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
