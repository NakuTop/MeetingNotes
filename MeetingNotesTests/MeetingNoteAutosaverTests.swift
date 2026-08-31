import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingNoteAutosaverTests: XCTestCase {
    func testEveryDraftRevisionEventuallyPersistsLatestText() async throws {
        let delay = ControlledMeetingNoteDelay()
        let completion = MeetingNoteAutosaverCompletionCounter()
        let autosaver = MeetingNoteAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
            }
        )
        let meetingID = UUID()
        let noteID = UUID()
        var savedTexts: [String] = []

        autosaver.schedule(
            MeetingNoteSaveRequest(
                meetingID: meetingID,
                noteID: noteID,
                timestamp: 4,
                text: "初稿",
                sequenceIndex: 0
            )
        ) { request in
            savedTexts.append(request.text)
        }
        await delay.waitForCallCount(1)

        autosaver.schedule(
            MeetingNoteSaveRequest(
                meetingID: meetingID,
                noteID: noteID,
                timestamp: 4,
                text: "最新文字",
                sequenceIndex: 0
            )
        ) { request in
            savedTexts.append(request.text)
        }
        await delay.waitForCallCount(2)

        delay.release(call: 0)
        await completion.wait(for: 1)
        XCTAssertTrue(savedTexts.isEmpty)

        delay.release(call: 1)
        await completion.wait(for: 2)
        XCTAssertEqual(savedTexts, ["最新文字"])
        XCTAssertEqual(autosaver.state, .saved)
    }
}

@MainActor
private final class ControlledMeetingNoteDelay {
    private(set) var durations: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var callCountWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func suspend(for duration: Duration) async throws {
        let call = durations.count
        durations.append(duration)
        resumeSatisfiedWaiters()
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

    private func resumeSatisfiedWaiters() {
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

@MainActor
private final class MeetingNoteAutosaverCompletionCounter {
    private var count = 0
    private var waiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func signal() {
        count += 1
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in waiters {
            if count >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}
