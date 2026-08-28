import XCTest
@testable import MeetingNotes

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    func testAutomaticCheckNeverInstallsWithoutUserAction() {
        let source = MutableUpdateActivitySource(states: [.idle])
        let driver = RecordingApplicationUpdateDriver()
        let coordinator = makeCoordinator(source: source, driver: driver)

        coordinator.updateDidBecomeAvailable(source: .automatic)
        coordinator.refreshDeferredInstallationState()

        XCTAssertEqual(driver.installCallCount, 0)
        XCTAssertEqual(coordinator.state, .updateAvailable)
    }

    func testBusyInstallRequestIsDeferredWithoutAutomaticRestart()
        async {
        let source = MutableUpdateActivitySource(states: [.recording])
        let driver = RecordingApplicationUpdateDriver()
        let flusher = RecordingPendingMeetingEditFlusher()
        let coordinator = makeCoordinator(
            source: source,
            driver: driver,
            flusher: flusher
        )
        coordinator.updateDidBecomeAvailable(source: .userInitiated)

        await coordinator.requestInstallation()

        XCTAssertEqual(
            coordinator.state,
            .deferred(.activeMeeting(.recording))
        )
        XCTAssertEqual(driver.installCallCount, 0)
        XCTAssertEqual(flusher.flushCallCount, 0)
    }

    func testPendingInstallRunsOnlyAfterIdleAndSecondUserAction()
        async {
        let source = MutableUpdateActivitySource(states: [.paused])
        let driver = RecordingApplicationUpdateDriver()
        let flusher = RecordingPendingMeetingEditFlusher()
        let coordinator = makeCoordinator(
            source: source,
            driver: driver,
            flusher: flusher
        )
        coordinator.updateDidBecomeAvailable(source: .automatic)
        await coordinator.requestInstallation()
        XCTAssertEqual(driver.installCallCount, 0)

        source.states = [.ready]
        coordinator.refreshDeferredInstallationState()

        XCTAssertEqual(coordinator.state, .awaitingUserConfirmation)
        XCTAssertEqual(driver.installCallCount, 0)
        XCTAssertEqual(flusher.flushCallCount, 0)

        await coordinator.requestInstallation()

        XCTAssertEqual(flusher.flushCallCount, 1)
        XCTAssertEqual(driver.installCallCount, 1)
        XCTAssertEqual(coordinator.state, .installing)
    }

    func testPreflightFlushFailurePreventsRestart() async {
        let source = MutableUpdateActivitySource(states: [.idle])
        let driver = RecordingApplicationUpdateDriver()
        let flusher = RecordingPendingMeetingEditFlusher(
            error: UpdateCoordinatorTestError.flushFailed
        )
        let coordinator = makeCoordinator(
            source: source,
            driver: driver,
            flusher: flusher
        )
        coordinator.updateDidBecomeAvailable(source: .userInitiated)

        await coordinator.requestInstallation()

        XCTAssertEqual(flusher.flushCallCount, 1)
        XCTAssertEqual(driver.installCallCount, 0)
        XCTAssertEqual(coordinator.state, .preflightFailed)
    }

    func testActivityIsRecheckedAfterFlushingPendingEdits() async {
        let source = MutableUpdateActivitySource(states: [.idle])
        let driver = RecordingApplicationUpdateDriver()
        let flusher = RecordingPendingMeetingEditFlusher {
            source.states = [.finalizing]
        }
        let coordinator = makeCoordinator(
            source: source,
            driver: driver,
            flusher: flusher
        )
        coordinator.updateDidBecomeAvailable(source: .userInitiated)

        await coordinator.requestInstallation()

        XCTAssertEqual(driver.installCallCount, 0)
        XCTAssertEqual(
            coordinator.state,
            .deferred(.activeMeeting(.finalizing))
        )
    }

    func testManualCheckAndAutomaticPreferenceForwardToDriver() {
        let source = MutableUpdateActivitySource(states: [.idle])
        let driver = RecordingApplicationUpdateDriver()
        let coordinator = makeCoordinator(source: source, driver: driver)

        coordinator.automaticallyChecksForUpdates = false
        coordinator.checkForUpdates()

        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.checkCallCount, 1)
        XCTAssertTrue(coordinator.canCheckForUpdates)
    }

    private func makeCoordinator(
        source: MutableUpdateActivitySource,
        driver: RecordingApplicationUpdateDriver,
        flusher: RecordingPendingMeetingEditFlusher =
            RecordingPendingMeetingEditFlusher()
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            driver: driver,
            activityPolicy: UpdateActivityPolicy(
                loadMeetingStates: { source.states }
            ),
            editFlusher: flusher
        )
    }
}

@MainActor
private final class MutableUpdateActivitySource {
    var states: [RecordingState]

    init(states: [RecordingState]) {
        self.states = states
    }
}

@MainActor
private final class RecordingApplicationUpdateDriver:
    ApplicationUpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    private(set) var checkCallCount = 0
    private(set) var installCallCount = 0

    func checkForUpdates() {
        checkCallCount += 1
    }

    func installDeferredUpdate() {
        installCallCount += 1
    }
}

@MainActor
private final class RecordingPendingMeetingEditFlusher:
    PendingMeetingEditFlushing {
    private let error: Error?
    private let onFlush: @MainActor () -> Void
    private(set) var flushCallCount = 0

    init(
        error: Error? = nil,
        onFlush: @escaping @MainActor () -> Void = {}
    ) {
        self.error = error
        self.onFlush = onFlush
    }

    convenience init(onFlush: @escaping @MainActor () -> Void) {
        self.init(error: nil, onFlush: onFlush)
    }

    func flushAllEdits() async throws {
        flushCallCount += 1
        onFlush()
        if let error { throw error }
    }
}

private enum UpdateCoordinatorTestError: Error {
    case flushFailed
}
