import Foundation

enum MeetingOperationKind: Equatable, Sendable {
    case rename
    case delete
    case summarizeArchive
}

@MainActor
final class MeetingOperationGate {
    private var activeOperations: [UUID: MeetingOperationKind] = [:]

    func acquire(
        _ operation: MeetingOperationKind,
        for meetingID: UUID
    ) -> Bool {
        guard activeOperations[meetingID] == nil else { return false }
        activeOperations[meetingID] = operation
        return true
    }

    func release(
        _ operation: MeetingOperationKind,
        for meetingID: UUID
    ) {
        guard activeOperations[meetingID] == operation else { return }
        activeOperations[meetingID] = nil
    }

    func isActive(for meetingID: UUID) -> Bool {
        activeOperations[meetingID] != nil
    }
}
