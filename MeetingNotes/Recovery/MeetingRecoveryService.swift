import Foundation

struct RecoveryCandidate: Equatable, Sendable {
    let meetingID: UUID
    let interruptedState: RecordingState
    let completeSegmentCount: Int
    let incompleteSegmentCount: Int
    let transcriptCount: Int
    let bookmarkCount: Int
}

enum MeetingRecoveryError: Error, Equatable, Sendable {
    case invalidTargetState(RecordingState)
    case meetingNotInterrupted(UUID)
}

@MainActor
final class MeetingRecoveryService {
    private let repository: MeetingRepository
    private let fileStore: MeetingFileStore

    init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore
    ) {
        self.repository = repository
        self.fileStore = fileStore
    }

    func scan() async throws -> [RecoveryCandidate] {
        var candidates: [RecoveryCandidate] = []

        for meeting in try repository.meetings()
        where Self.interruptedStates.contains(meeting.state) {
            let manifest = try await manifestOrEmpty(meetingID: meeting.id)
            candidates.append(
                RecoveryCandidate(
                    meetingID: meeting.id,
                    interruptedState: meeting.state,
                    completeSegmentCount: manifest.segments.count(where: \.isComplete),
                    incompleteSegmentCount: manifest.segments.count {
                        !$0.isComplete
                    },
                    transcriptCount: meeting.transcripts.count,
                    bookmarkCount: meeting.bookmarks.count
                )
            )
        }

        return candidates
    }

    func recover(
        meetingID: UUID,
        targetState: RecordingState
    ) async throws {
        guard targetState == .ready || targetState == .finalizing else {
            throw MeetingRecoveryError.invalidTargetState(targetState)
        }

        let meeting = try repository.meeting(id: meetingID)
        guard Self.interruptedStates.contains(meeting.state) else {
            throw MeetingRecoveryError.meetingNotInterrupted(meetingID)
        }

        var manifest = try await manifestOrEmpty(meetingID: meetingID)
        manifest.segments.removeAll { !$0.isComplete }
        try await fileStore.saveManifest(manifest, meetingID: meetingID)
        try repository.updateMeetingState(id: meetingID, state: targetState)
    }

    private func manifestOrEmpty(
        meetingID: UUID
    ) async throws -> AudioSegmentManifest {
        do {
            return try await fileStore.loadManifest(meetingID: meetingID)
        } catch MeetingFileStoreError.manifestNotFound(let missingID)
            where missingID == meetingID {
            return AudioSegmentManifest()
        }
    }

    private static let interruptedStates: Set<RecordingState> = [
        .recording,
        .paused,
        .finalizing
    ]
}
