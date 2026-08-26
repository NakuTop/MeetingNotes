import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingEditAutosaverTests: XCTestCase {
    func testRepeatedKeystrokesCoalesceToLatestSnapshot() async throws {
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
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
        try await completion.wait(for: 1)
        XCTAssertTrue(savedValues.isEmpty)
        delay.release(call: 1)
        try await completion.wait(for: 2)

        XCTAssertEqual(savedValues, ["latest"])
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testFlushPersistsImmediatelyAndCancelsPendingDelay() async throws {
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
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
        try await completion.wait(for: 1)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testOldSaveCompletionCannotClearNewDirtyDraft() async throws {
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
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
        try await completion.wait(for: 1)
        await delay.waitForCallCount(2)

        XCTAssertEqual(savedValues, ["old"])
        XCTAssertEqual(autosaver.state, .idle)

        delay.release(call: 1)
        try await completion.wait(for: 2)
        XCTAssertEqual(savedValues, ["old", "new"])
        XCTAssertEqual(autosaver.state, .saved)
    }

    func testSaveFailureKeepsDraftAndExposesRetryState() async throws {
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
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
        try await completion.wait(for: 1)

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

    func testCancelPreventsDelayedSaveAndStaleStateChange() async throws {
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
            }
        )
        var saveCount = 0
        autosaver.schedule {
            saveCount += 1
        }
        await delay.waitForCallCount(1)

        autosaver.cancel()
        delay.release(call: 0)
        try await completion.wait(for: 1)

        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(autosaver.state, .idle)
        await autosaver.retry()
        XCTAssertEqual(saveCount, 0)
    }

    func testCompletionBarrierCancellationIsSingleResume() async throws {
        let registration = ControlledMeetingEditDelay()
        let barrier = MeetingEditAutosaverCompletionBarrier(
            onWaiterPrepared: {
                try? await registration.suspend(for: .zero)
            }
        )
        let waiter = Task {
            try await barrier.wait(for: 1)
        }
        await registration.waitForCallCount(1)

        waiter.cancel()
        registration.release(call: 0)
        do {
            try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected terminal result.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }

        barrier.signal()
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

private final class MeetingEditAutosaverCompletionBarrier:
    @unchecked Sendable {
    private enum TerminalResult {
        case completed
        case cancelled
    }

    private enum WaiterState {
        case registering(target: Int)
        case waiting(
            target: Int,
            continuation: CheckedContinuation<Void, any Error>
        )
        case terminal(TerminalResult)
    }

    private let lock = NSLock()
    private let onWaiterPrepared: @Sendable () async -> Void
    private var completionCount = 0
    private var waiters: [UUID: WaiterState] = [:]

    init(onWaiterPrepared: @escaping @Sendable () async -> Void = {}) {
        self.onWaiterPrepared = onWaiterPrepared
    }

    func signal() {
        var continuations: [CheckedContinuation<Void, any Error>] = []
        lock.lock()
        completionCount += 1
        for (id, state) in Array(waiters) {
            switch state {
            case let .registering(target) where completionCount >= target:
                waiters[id] = .terminal(.completed)
            case let .waiting(target, continuation)
                where completionCount >= target:
                waiters.removeValue(forKey: id)
                continuations.append(continuation)
            case .registering, .waiting, .terminal:
                break
            }
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func wait(for target: Int) async throws {
        precondition(target > 0)
        try Task.checkCancellation()
        let waiterID = UUID()
        guard prepare(waiterID: waiterID, target: target) else { return }
        await onWaiterPrepared()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    private func prepare(waiterID: UUID, target: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completionCount < target else { return false }
        waiters[waiterID] = .registering(target: target)
        return true
    }

    private func register(
        waiterID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        var terminal: TerminalResult?
        lock.lock()
        switch waiters[waiterID] {
        case let .registering(target):
            if completionCount >= target {
                waiters.removeValue(forKey: waiterID)
                terminal = .completed
            } else {
                waiters[waiterID] = .waiting(
                    target: target,
                    continuation: continuation
                )
            }
        case let .terminal(result):
            waiters.removeValue(forKey: waiterID)
            terminal = result
        case .waiting, nil:
            terminal = .cancelled
        }
        lock.unlock()

        switch terminal {
        case .completed:
            continuation.resume()
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        case nil:
            break
        }
    }

    private func cancel(waiterID: UUID) {
        var continuation: CheckedContinuation<Void, any Error>?
        lock.lock()
        switch waiters[waiterID] {
        case .registering:
            waiters[waiterID] = .terminal(.cancelled)
        case let .waiting(_, pendingContinuation):
            waiters.removeValue(forKey: waiterID)
            continuation = pendingContinuation
        case .terminal, nil:
            break
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
