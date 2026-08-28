enum UpdateDiscoverySource: Equatable, Sendable {
    case automatic
    case userInitiated
}

enum UpdateActivityBlocker: Equatable, Sendable {
    case activeMeeting(RecordingState)
    case repositoryUnavailable

    var message: String {
        switch self {
        case .activeMeeting:
            "会议正在进行或处理中，请结束后再安装更新。"
        case .repositoryUnavailable:
            "暂时无法确认会议状态，已为你阻止安装。"
        }
    }
}

enum UpdateActivityDecision: Equatable, Sendable {
    case allowed
    case blocked(UpdateActivityBlocker)
}

enum UpdateCoordinatorState: Equatable, Sendable {
    case idle
    case updateAvailable
    case deferred(UpdateActivityBlocker)
    case awaitingUserConfirmation
    case preflightFailed
    case installing
}

@MainActor
protocol ApplicationUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }

    func checkForUpdates()
    func installDeferredUpdate()
}

@MainActor
protocol PendingMeetingEditFlushing: AnyObject {
    func flushAllEdits() async throws
}
