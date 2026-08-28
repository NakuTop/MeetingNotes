import Observation

@MainActor
@Observable
final class UpdateCoordinator {
    private let driver: ApplicationUpdateDriving
    private let activityPolicy: UpdateActivityPolicy
    private let editFlusher: PendingMeetingEditFlushing
    private var hasAvailableUpdate = false

    private(set) var state: UpdateCoordinatorState = .idle

    init(
        driver: ApplicationUpdateDriving,
        activityPolicy: UpdateActivityPolicy,
        editFlusher: PendingMeetingEditFlushing
    ) {
        self.driver = driver
        self.activityPolicy = activityPolicy
        self.editFlusher = editFlusher
    }

    var canCheckForUpdates: Bool {
        driver.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { driver.automaticallyChecksForUpdates }
        set { driver.automaticallyChecksForUpdates = newValue }
    }

    var blockerMessage: String? {
        guard case let .deferred(blocker) = state else {
            return nil
        }
        return blocker.message
    }

    func checkForUpdates() {
        guard driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func updateDidBecomeAvailable(source: UpdateDiscoverySource) {
        _ = source
        hasAvailableUpdate = true
        state = .updateAvailable
    }

    func refreshDeferredInstallationState() {
        guard case .deferred = state else { return }

        switch activityPolicy.installationDecision() {
        case .allowed:
            state = .awaitingUserConfirmation
        case let .blocked(blocker):
            state = .deferred(blocker)
        }
    }

    func requestInstallation() async {
        guard hasAvailableUpdate,
              state != .installing else {
            return
        }

        switch activityPolicy.installationDecision() {
        case .allowed:
            break
        case let .blocked(blocker):
            state = .deferred(blocker)
            return
        }

        do {
            try await editFlusher.flushAllEdits()
        } catch {
            state = .preflightFailed
            return
        }

        switch activityPolicy.installationDecision() {
        case .allowed:
            state = .installing
            hasAvailableUpdate = false
            driver.installDeferredUpdate()
        case let .blocked(blocker):
            state = .deferred(blocker)
        }
    }
}
