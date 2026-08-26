import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingEditAutosaverTests: XCTestCase {
    func testRepeatedKeystrokesCoalesceToLatestSnapshot() async {
        let delay = ControlledMeetingEditDelay()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            }
        )
        var savedValues: [String] = []

        autosaver.schedule {
            savedValues.append("first")
        }
        await delay.waitForCallCount(1)
        autosaver.schedule {
            savedValues.append("latest")
        }
        await delay.waitForCallCount(2)

        XCTAssertEqual(
            delay.durations,
            [.milliseconds(350), .milliseconds(350)]
        )
        delay.release(call: 0)
        delay.release(call: 1)
        await yieldToScheduledTasks()

        XCTAssertEqual(savedValues, ["latest"])
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testFlushPersistsImmediatelyAndCancelsPendingDelay() async {
        let delay = ControlledMeetingEditDelay()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            }
        )
        var saveCount = 0
        autosaver.schedule {
            saveCount += 1
        }
        await delay.waitForCallCount(1)

        await autosaver.flush()

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(autosaver.state, .saved)
        delay.release(call: 0)
        await yieldToScheduledTasks()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testOldSaveCompletionCannotClearNewDirtyDraft() async {
        let delay = ControlledMeetingEditDelay()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            }
        )
        var savedValues: [String] = []

        autosaver.schedule {
            savedValues.append("old")
            autosaver.schedule {
                savedValues.append("new")
            }
        }
        await delay.waitForCallCount(1)
        delay.release(call: 0)
        await delay.waitForCallCount(2)

        XCTAssertEqual(savedValues, ["old"])
        XCTAssertEqual(autosaver.state, .idle)

        delay.release(call: 1)
        await yieldToScheduledTasks()
        XCTAssertEqual(savedValues, ["old", "new"])
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testSaveFailureKeepsDraftAndExposesRetryState() async {
        let delay = ControlledMeetingEditDelay()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            }
        )
        let failure = MeetingEditAutosaverFailureSwitch()
        var attempts = 0
        autosaver.schedule {
            attempts += 1
            if failure.shouldFail {
                throw MeetingEditAutosaverTestError.forced
            }
        }
        await delay.waitForCallCount(1)
        delay.release(call: 0)
        await yieldToScheduledTasks()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            autosaver.state,
            .failed(message: "无法自动保存本地修改，请稍后重试。")
        )

        failure.shouldFail = false
        await autosaver.retry()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testCancelPreventsDelayedSaveAndStaleStateChange() async {
        let delay = ControlledMeetingEditDelay()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            }
        )
        var saveCount = 0
        autosaver.schedule {
            saveCount += 1
        }
        await delay.waitForCallCount(1)

        autosaver.cancel()
        delay.release(call: 0)
        await yieldToScheduledTasks()

        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(autosaver.state, .idle)
        await autosaver.retry()
        XCTAssertEqual(saveCount, 0)
    }

    private func yieldToScheduledTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

@MainActor
private final class ControlledMeetingEditDelay {
    private(set) var durations: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var callCountWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func suspend(for duration: Duration) async throws {
        let call = durations.count
        durations.append(duration)
        resumeSatisfiedCallCountWaiters()
        try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func release(call: Int) {
        pending.removeValue(forKey: call)?.resume()
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remaining: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in callCountWaiters {
            if durations.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

private enum MeetingEditAutosaverTestError: Error {
    case forced
}

@MainActor
private final class MeetingEditAutosaverFailureSwitch {
    var shouldFail = true
}
