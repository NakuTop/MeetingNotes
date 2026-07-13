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
