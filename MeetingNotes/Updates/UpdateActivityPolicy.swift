@MainActor
struct UpdateActivityPolicy {
    typealias MeetingStateLoader = @MainActor () throws -> [RecordingState]

    private let loadMeetingStates: MeetingStateLoader

    init(repository: MeetingRepository) {
        loadMeetingStates = {
            try repository.meetings().map(\.state)
        }
    }

    init(loadMeetingStates: @escaping MeetingStateLoader) {
        self.loadMeetingStates = loadMeetingStates
    }

    func installationDecision() -> UpdateActivityDecision {
        do {
            let states = try loadMeetingStates()
            if let blockingState = states.first(
                where: Self.blocksInstallation
            ) {
                return .blocked(.activeMeeting(blockingState))
            }
            return .allowed
        } catch {
            return .blocked(.repositoryUnavailable)
        }
    }

    private static func blocksInstallation(_ state: RecordingState) -> Bool {
        switch state {
        case .preparing, .recording, .paused, .finalizing, .summarizing,
             .archiving:
            true
        case .idle, .ready, .summaryReady, .archived:
            false
        }
    }
}
