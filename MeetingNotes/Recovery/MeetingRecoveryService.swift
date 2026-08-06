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
    private let recoveryCutoff: Date

    init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore,
        recoveryCutoff: Date = .now
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.recoveryCutoff = recoveryCutoff
    }

    func scan() async throws -> [RecoveryCandidate] {
        var candidates: [RecoveryCandidate] = []

        for meeting in try repository.meetings() {
            guard Self.interruptedStates.contains(meeting.state),
                  meeting.startedAt <= recoveryCutoff else {
                continue
            }
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

        let tracks: [AudioTrack] = meeting.mode == .online
            ? [.master, .microphone, .system]
            : [.master]
        var durations: [AudioTrack: TimeInterval] = [:]
        for track in tracks {
            if let duration = try await repairManifest(
                meetingID: meetingID,
                track: track
            ) {
                durations[track] = duration
            }
        }

        if targetState == .ready {
            let activeDuration = durations[.master]
                ?? durations.values.max()
                ?? 0
            try repository.finalizeInterruptedMeeting(
                id: meetingID,
                endedAt: meeting.startedAt.addingTimeInterval(
                    activeDuration
                ),
                activeDuration: activeDuration,
                lastErrorCode: "capture_interrupted_recovered"
            )
        } else {
            try repository.updateMeetingState(
                id: meetingID,
                state: targetState
            )
        }
    }

    func recoverAllInterruptedMeetings() async throws -> [UUID] {
        let candidates = try await scan()
        var recovered: [UUID] = []
        for candidate in candidates {
            try await recover(
                meetingID: candidate.meetingID,
                targetState: .ready
            )
            recovered.append(candidate.meetingID)
        }
        return recovered
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

    private func repairManifest(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> TimeInterval? {
        let manifest: AudioSegmentManifest
        do {
            manifest = try await fileStore.loadManifest(
                meetingID: meetingID,
                track: track
            )
        } catch MeetingFileStoreError.manifestNotFound(let missingID)
            where missingID == meetingID {
            return nil
        }

        var repaired = manifest
        repaired.segments.removeAll { !$0.isComplete }
        try await fileStore.saveManifest(
            repaired,
            meetingID: meetingID,
            track: track
        )
        return repaired.segments.map(\.endTime).max() ?? 0
    }

    private static let interruptedStates: Set<RecordingState> = [
        .recording,
        .paused,
        .finalizing
    ]
}
