enum RecordingState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case finalizing
    case ready
    case summarizing
    case summaryReady
    case archiving
    case archived

    var blocksCaptureSettingsChanges: Bool {
        switch self {
        case .preparing, .recording, .paused, .finalizing:
            true
        case .idle, .ready, .summarizing, .summaryReady, .archiving,
             .archived:
            false
        }
    }

    var allowsInterruptedSpeakerDiarizationRetryRecovery: Bool {
        switch self {
        case .ready, .summaryReady, .archived:
            true
        case .idle, .preparing, .recording, .paused, .finalizing,
             .summarizing, .archiving:
            false
        }
    }
}

enum RecordingAction: String, Codable, CaseIterable, Equatable, Sendable {
    case prepare
    case start
    case pause
    case resume
    case stop
    case finalized
    case bookmark
    case summarize
    case summarySucceeded
    case summaryFailed
    case archive
    case archiveSucceeded
    case archiveFailed
}

enum RecordingStateError: Error, Equatable, Sendable {
    case invalidTransition(RecordingState, RecordingAction)
}
