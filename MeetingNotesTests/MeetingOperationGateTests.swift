import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingOperationGateTests: XCTestCase {
    func testAcquireWhenAvailableWaitsThenTransfersOwnership() async {
        let gate = MeetingOperationGate()
        let meetingID = UUID()
        let probe = OperationAcquisitionProbe()
        XCTAssertTrue(
            gate.acquire(.summarizeArchive, for: meetingID)
        )

        let waitingDelete = Task {
            try await gate.acquireWhenAvailable(.delete, for: meetingID)
            await probe.markAcquired()
        }
        await Task.yield()

        let acquiredWhileBlocked = await probe.hasAcquired()
        XCTAssertFalse(acquiredWhileBlocked)
        XCTAssertTrue(gate.isActive(for: meetingID))

        gate.release(.summarizeArchive, for: meetingID)
        try? await waitingDelete.value

        let acquiredAfterRelease = await probe.hasAcquired()
        XCTAssertTrue(acquiredAfterRelease)
        XCTAssertTrue(gate.isActive(for: meetingID))
        XCTAssertFalse(gate.acquire(.rename, for: meetingID))
        gate.release(.delete, for: meetingID)
        XCTAssertFalse(gate.isActive(for: meetingID))
    }

    func testCancelledWaiterDoesNotTakeOwnershipAfterRelease() async {
        let gate = MeetingOperationGate()
        let meetingID = UUID()
        XCTAssertTrue(gate.acquire(.rename, for: meetingID))
        let waitingDelete = Task {
            try await gate.acquireWhenAvailable(.delete, for: meetingID)
        }
        await Task.yield()

        waitingDelete.cancel()
        do {
            try await waitingDelete.value
            XCTFail("Expected waiting acquisition to cancel")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        gate.release(.rename, for: meetingID)
        XCTAssertFalse(gate.isActive(for: meetingID))
        XCTAssertTrue(gate.acquire(.summarizeArchive, for: meetingID))
    }
}

private actor OperationAcquisitionProbe {
    private var acquired = false

    func markAcquired() {
        acquired = true
    }

    func hasAcquired() -> Bool {
        acquired
    }
}
