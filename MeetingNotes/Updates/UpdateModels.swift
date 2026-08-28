import Foundation

enum UpdateDiscoverySource: Equatable, Sendable {
    case automatic
    case userInitiated
}

enum ApplicationUpdateChannel: String, Equatable, Sendable {
    case stable
    case beta

    var displayName: String {
        switch self {
        case .stable:
            "正式版"
        case .beta:
            "Beta"
        }
    }
}

struct ApplicationUpdateAbout: Equatable, Sendable {
    let version: String
    let build: String
    let channel: ApplicationUpdateChannel

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> ApplicationUpdateAbout {
        let version = infoDictionary["CFBundleShortVersionString"] as? String
            ?? "--"
        let build = infoDictionary["CFBundleVersion"] as? String ?? "--"
        let channelRawValue = infoDictionary[
            "MeetingNotesUpdateChannel"
        ] as? String
        let channel = ApplicationUpdateChannel(
            rawValue: channelRawValue?.lowercased() ?? ""
        ) ?? .stable
        return ApplicationUpdateAbout(
            version: version,
            build: build,
            channel: channel
        )
    }
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
    case checkFailed
    case deferred(UpdateActivityBlocker)
    case awaitingUserConfirmation
    case preflightFailed
    case installing
}

@MainActor
protocol ApplicationUpdateDriving: AnyObject {
    var isUpdateServiceEnabled: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var hasDeferredInstallation: Bool { get }

    func checkForUpdates()
    func installDeferredUpdate()
}

@MainActor
final class InertApplicationUpdateDriver: ApplicationUpdateDriving {
    let isUpdateServiceEnabled = false
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    let hasDeferredInstallation = false

    func checkForUpdates() {}
    func installDeferredUpdate() {}
}

@MainActor
protocol PendingMeetingEditFlushing: AnyObject {
    func flushAllEdits() async throws
}
