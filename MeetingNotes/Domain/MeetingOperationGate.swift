import Foundation

enum MeetingOperationKind: Equatable, Sendable {
    case rename
    case delete
    case summarizeArchive
    case speakerDiarizationRetry
}

@MainActor
final class MeetingOperationGate {
    private struct Waiter {
        let id: UUID
        let operation: MeetingOperationKind
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeOperations: [UUID: MeetingOperationKind] = [:]
    private var waiters: [UUID: [Waiter]] = [:]

    func acquire(
        _ operation: MeetingOperationKind,
        for meetingID: UUID
    ) -> Bool {
        guard activeOperations[meetingID] == nil else { return false }
        activeOperations[meetingID] = operation
        return true
    }

    func acquireWhenAvailable(
        _ operation: MeetingOperationKind,
        for meetingID: UUID
    ) async throws {
        try Task.checkCancellation()
        if acquire(operation, for: meetingID) {
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[meetingID, default: []].append(
                        Waiter(
                            id: waiterID,
                            operation: operation,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWaiter(waiterID, for: meetingID)
            }
        }

        guard acquired, !Task.isCancelled else {
            if acquired {
                release(operation, for: meetingID)
            }
            throw CancellationError()
        }
    }

    func release(
        _ operation: MeetingOperationKind,
        for meetingID: UUID
    ) {
        guard activeOperations[meetingID] == operation else { return }
        activeOperations[meetingID] = nil
        resumeNextWaiter(for: meetingID)
    }

    func isActive(for meetingID: UUID) -> Bool {
        activeOperations[meetingID] != nil
    }

    private func cancelWaiter(_ waiterID: UUID, for meetingID: UUID) {
        guard var queued = waiters[meetingID],
              let index = queued.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = queued.remove(at: index)
        waiters[meetingID] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }

    private func resumeNextWaiter(for meetingID: UUID) {
        guard var queued = waiters[meetingID], !queued.isEmpty else {
            waiters[meetingID] = nil
            return
        }
        let waiter = queued.removeFirst()
        waiters[meetingID] = queued.isEmpty ? nil : queued
        activeOperations[meetingID] = waiter.operation
        waiter.continuation.resume(returning: true)
    }
}
