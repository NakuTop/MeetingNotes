struct RecordingStateMachine: Sendable {
    private(set) var state: RecordingState

    init(state: RecordingState = .idle) {
        self.state = state
    }

    mutating func send(_ action: RecordingAction) throws {
        switch (state, action) {
        case (.idle, .prepare):
            state = .preparing
        case (.preparing, .start):
            state = .recording
        case (.recording, .pause):
            state = .paused
        case (.paused, .resume):
            state = .recording
        case (.recording, .stop), (.paused, .stop):
            state = .finalizing
        case (.finalizing, .finalized):
            state = .ready
        case (.recording, .bookmark), (.paused, .bookmark):
            break
        case (.ready, .summarize):
            state = .summarizing
        case (.summarizing, .summarySucceeded):
            state = .summaryReady
        case (.summarizing, .summaryFailed):
            state = .ready
        case (.summaryReady, .archive):
            state = .archiving
        case (.archiving, .archiveSucceeded):
            state = .archived
        case (.archiving, .archiveFailed):
            state = .summaryReady
        default:
            throw RecordingStateError.invalidTransition(state, action)
        }
    }
}
