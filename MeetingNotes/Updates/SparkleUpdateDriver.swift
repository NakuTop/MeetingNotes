import Foundation
import Sparkle

struct SparkleUpdateConfiguration: Equatable, Sendable {
    let channel: ApplicationUpdateChannel
    let feedURL: URL
    let publicEDKey: String?
    let isEnabled: Bool
    let isUITesting: Bool

    init?(
        infoDictionary: [String: Any],
        isUITesting: Bool
    ) {
        let rawChannel = infoDictionary[
            "MeetingNotesUpdateChannel"
        ] as? String
        guard let channel = ApplicationUpdateChannel(
            rawValue: rawChannel?.lowercased() ?? ""
        ),
        let feed = infoDictionary["SUFeedURL"] as? String,
        let feedURL = URL(string: feed),
        feedURL.scheme?.lowercased() == "https" else {
            return nil
        }

        let rawPublicKey = (infoDictionary["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicEDKey: String?
        if let rawPublicKey,
           !rawPublicKey.isEmpty,
           !rawPublicKey.contains("$(") {
            publicEDKey = rawPublicKey
        } else {
            publicEDKey = nil
        }

        let enabledValue = infoDictionary[
            "MeetingNotesUpdatesEnabled"
        ]
        let isEnabled = switch enabledValue {
        case let value as Bool:
            value
        case let value as String:
            (value as NSString).boolValue
        default:
            false
        }

        self.channel = channel
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
        self.isEnabled = isEnabled
        self.isUITesting = isUITesting
    }

    var shouldStartUpdater: Bool {
        isEnabled && !isUITesting && publicEDKey != nil
    }

    static func current(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> SparkleUpdateConfiguration? {
        SparkleUpdateConfiguration(
            infoDictionary: bundle.infoDictionary ?? [:],
            isUITesting: LaunchArguments.isUITesting(arguments)
        )
    }
}

@MainActor
final class SparkleUpdateDriver: NSObject, ApplicationUpdateDriving {
    private let configuration: SparkleUpdateConfiguration?
    private var updaterController: SPUStandardUpdaterController?
    private var nextDiscoverySource: UpdateDiscoverySource = .automatic
    private var deferredInstallHandler: (() -> Void)?

    var onUpdateFound: (@MainActor (UpdateDiscoverySource) -> Void)?
    var onNoUpdateFound: (@MainActor () -> Void)?
    var onRelaunchRequested: (@MainActor () -> Void)?
    var onUpdateCheckFailed: (@MainActor () -> Void)?

    init(configuration: SparkleUpdateConfiguration?) {
        self.configuration = configuration
        super.init()

        guard configuration?.shouldStartUpdater == true else { return }
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        updaterController.startUpdater()
    }

    var isUpdateServiceEnabled: Bool {
        configuration?.shouldStartUpdater == true
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var hasDeferredInstallation: Bool {
        deferredInstallHandler != nil
    }

    func checkForUpdates() {
        guard let updaterController,
              updaterController.updater.canCheckForUpdates else {
            return
        }
        nextDiscoverySource = .userInitiated
        updaterController.updater.checkForUpdates()
    }

    func installDeferredUpdate() {
        guard let deferredInstallHandler else { return }
        self.deferredInstallHandler = nil
        deferredInstallHandler()
    }
}

extension SparkleUpdateDriver: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        _ = updater
        _ = item
        let source = nextDiscoverySource
        nextDiscoverySource = .automatic
        onUpdateFound?(source)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        _ = updater
        _ = item
        guard let onRelaunchRequested else { return false }
        deferredInstallHandler = installHandler
        onRelaunchRequested()
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        _ = updater
        nextDiscoverySource = .automatic
        onNoUpdateFound?()
    }

    func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: any Error
    ) {
        _ = updater
        _ = error
        nextDiscoverySource = .automatic
        onUpdateCheckFailed?()
    }
}
