import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class OnboardingStateTests: XCTestCase {
    func testPrivacyAndRecordingConsentAppearsOnlyUntilConfirmed() throws {
        let suiteName = "OnboardingStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstLaunch = OnboardingState(defaults: defaults)

        XCTAssertTrue(firstLaunch.shouldPresentPrivacyAndConsent)
        XCTAssertFalse(firstLaunch.hasConfirmedRecordingConsent)

        firstLaunch.completePrivacyAndConsent()
        let nextLaunch = OnboardingState(defaults: defaults)

        XCTAssertFalse(nextLaunch.shouldPresentPrivacyAndConsent)
        XCTAssertTrue(nextLaunch.hasConfirmedRecordingConsent)
    }

    func testModelNotReadyStillAllowsRecordingWithoutClaimingRealtimeTranscription() {
        for status in [
            TranscriptionModelStatus.notDownloaded,
            .downloading,
            .failed
        ] {
            XCTAssertTrue(status.allowsRecording)
            XCTAssertFalse(status.displaysRealtimeTranscription)
        }
        XCTAssertTrue(TranscriptionModelStatus.ready.allowsRecording)
        XCTAssertTrue(
            TranscriptionModelStatus.ready.displaysRealtimeTranscription
        )
    }

    func testFailedModelPreparationCanRetryToReady() async {
        let preparer = ModelPreparerStub(
            results: [
                .failure(ModelPreparationTestError.failed),
                .success(())
            ]
        )
        let viewModel = TranscriptionModelViewModel(preparer: preparer)

        await viewModel.prepareIfNeeded()
        XCTAssertEqual(viewModel.status, .failed)
        XCTAssertTrue(viewModel.canRetry)

        await viewModel.retry()
        XCTAssertEqual(viewModel.status, .ready)
        XCTAssertFalse(viewModel.canRetry)
        let callCount = await preparer.callCount()
        XCTAssertEqual(callCount, 2)
    }
}

private enum ModelPreparationTestError: Error {
    case failed
}

private actor ModelPreparerStub: TranscriptionModelPreparing {
    private var results: [Result<Void, Error>]
    private var calls = 0

    init(results: [Result<Void, Error>]) {
        self.results = results
    }

    func prepare() async throws {
        calls += 1
        guard !results.isEmpty else { return }
        try results.removeFirst().get()
    }

    func callCount() -> Int { calls }
}
