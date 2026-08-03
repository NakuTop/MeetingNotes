import XCTest
@testable import MeetingNotes

@MainActor
final class TranscriptionModelViewModelTests: XCTestCase {
    func testSelectingUndownloadedHighAccuracyDoesNotPrepareIt() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [
                .balanced: .ready,
                .highAccuracy: .notDownloaded
            ]
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .balanced
        )
        await viewModel.refreshStatuses()

        viewModel.selectedMode = .highAccuracy

        XCTAssertEqual(viewModel.selectedStatus, .notDownloaded)
        XCTAssertTrue(viewModel.canDownloadSelected)
        let preparedModes = await controller.preparedModes()
        XCTAssertEqual(preparedModes, [])
    }

    func testHighAccuracyCanOnlyBeSavedAfterExplicitPreparation() async {
        for status in [
            TranscriptionModelStatus.notDownloaded,
            .downloading,
            .failed,
        ] {
            let controller = RecordingTranscriptionModelController(
                statuses: [.highAccuracy: status]
            )
            let viewModel = TranscriptionModelViewModel(
                controller: controller,
                selectedMode: .highAccuracy
            )
            await viewModel.refreshStatuses()

            XCTAssertFalse(
                viewModel.canPersistSelection(mode: .highAccuracy)
            )
        }

        let readyController = RecordingTranscriptionModelController(
            statuses: [.highAccuracy: .ready]
        )
        let readyViewModel = TranscriptionModelViewModel(
            controller: readyController,
            selectedMode: .highAccuracy
        )
        await readyViewModel.refreshStatuses()

        XCTAssertTrue(
            readyViewModel.canPersistSelection(mode: .highAccuracy)
        )
        XCTAssertTrue(readyViewModel.canPersistSelection(mode: .balanced))
    }

    func testExplicitDownloadTransitionsHighAccuracyFromDownloadingToReady() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [.highAccuracy: .notDownloaded],
            blocksPreparation: true
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .highAccuracy
        )

        let download = Task { await viewModel.downloadSelected() }
        await controller.waitUntilPreparationStarts()

        XCTAssertEqual(viewModel.selectedStatus, .downloading)

        await controller.finishPreparation(with: .success(()))
        await download.value

        XCTAssertEqual(viewModel.selectedStatus, .ready)
        let preparedModes = await controller.preparedModes()
        XCTAssertEqual(preparedModes, [.highAccuracy])
    }

    func testFailedHighAccuracyDoesNotChangeBalancedStatus() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [
                .balanced: .ready,
                .highAccuracy: .notDownloaded
            ],
            preparationResults: [.failure(TestModelError.failed)]
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .highAccuracy
        )
        await viewModel.refreshStatuses()

        await viewModel.downloadSelected()

        XCTAssertEqual(viewModel.selectedStatus, .failed)
        viewModel.selectedMode = .balanced
        XCTAssertEqual(viewModel.selectedStatus, .ready)
    }

    func testRetrySelectedRetriesOnlyFailedHighAccuracy() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [
                .balanced: .ready,
                .highAccuracy: .notDownloaded
            ],
            preparationResults: [
                .failure(TestModelError.failed),
                .success(())
            ]
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .highAccuracy
        )
        await viewModel.refreshStatuses()
        await viewModel.downloadSelected()

        await viewModel.retrySelected()

        XCTAssertEqual(viewModel.selectedStatus, .ready)
        let preparedModes = await controller.preparedModes()
        XCTAssertEqual(preparedModes, [.highAccuracy, .highAccuracy])
        viewModel.selectedMode = .balanced
        XCTAssertEqual(viewModel.selectedStatus, .ready)
    }

    func testPrepareBalancedDoesNotPrepareSelectedHighAccuracy() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [
                .balanced: .notDownloaded,
                .highAccuracy: .notDownloaded
            ]
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .highAccuracy
        )

        await viewModel.prepareBalancedIfNeeded()

        let preparedModes = await controller.preparedModes()
        XCTAssertEqual(preparedModes, [.balanced])
        XCTAssertEqual(viewModel.selectedStatus, .notDownloaded)
    }

    func testExplicitModeDownloadKeepsOwnershipWhenSelectedModeChanges() async {
        let controller = RecordingTranscriptionModelController(
            statuses: [
                .balanced: .ready,
                .highAccuracy: .notDownloaded
            ],
            blocksPreparation: true
        )
        let viewModel = TranscriptionModelViewModel(
            controller: controller,
            selectedMode: .balanced
        )
        await viewModel.refreshStatuses()

        XCTAssertEqual(
            viewModel.descriptor(for: .highAccuracy).mode,
            .highAccuracy
        )
        XCTAssertTrue(viewModel.canDownload(mode: .highAccuracy))
        XCTAssertFalse(viewModel.canRetry(mode: .highAccuracy))

        let download = Task {
            await viewModel.download(mode: .highAccuracy)
        }
        await controller.waitUntilPreparationStarts()
        viewModel.selectedMode = .balanced

        XCTAssertEqual(viewModel.status(for: .balanced), .ready)
        XCTAssertEqual(viewModel.status(for: .highAccuracy), .downloading)

        await controller.finishPreparation(with: .success(()))
        await download.value

        XCTAssertEqual(viewModel.status(for: .balanced), .ready)
        XCTAssertEqual(viewModel.status(for: .highAccuracy), .ready)
        let preparedModes = await controller.preparedModes()
        XCTAssertEqual(preparedModes, [.highAccuracy])
    }
}

private enum TestModelError: Error {
    case failed
}

private actor RecordingTranscriptionModelController:
    TranscriptionModelControlling {
    private var statuses: [
        TranscriptionQualityMode: TranscriptionModelStatus
    ]
    private var preparationResults: [Result<Void, Error>]
    private let blocksPreparation: Bool
    private var prepareCalls: [TranscriptionQualityMode] = []
    private var preparationContinuation:
        CheckedContinuation<Result<Void, Error>, Never>?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparationHasStarted = false

    init(
        statuses: [
            TranscriptionQualityMode: TranscriptionModelStatus
        ] = [:],
        preparationResults: [Result<Void, Error>] = [.success(())],
        blocksPreparation: Bool = false
    ) {
        self.statuses = statuses
        self.preparationResults = preparationResults
        self.blocksPreparation = blocksPreparation
    }

    func status(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelStatus {
        statuses[mode] ?? .notDownloaded
    }

    func prepare(mode: TranscriptionQualityMode) async throws {
        prepareCalls.append(mode)
        preparationHasStarted = true
        preparationWaiters.forEach { $0.resume() }
        preparationWaiters.removeAll()
        statuses[mode] = .downloading

        let result: Result<Void, Error>
        if blocksPreparation {
            result = await withCheckedContinuation { continuation in
                preparationContinuation = continuation
            }
        } else if preparationResults.isEmpty {
            result = .success(())
        } else {
            result = preparationResults.removeFirst()
        }

        switch result {
        case .success:
            statuses[mode] = .ready
        case .failure:
            statuses[mode] = .failed
        }
        try result.get()
    }

    func service(
        mode: TranscriptionQualityMode
    ) async throws -> any TranscriptionService {
        throw TestModelError.failed
    }

    func preparedModes() -> [TranscriptionQualityMode] {
        prepareCalls
    }

    func waitUntilPreparationStarts() async {
        if preparationHasStarted { return }
        await withCheckedContinuation { continuation in
            preparationWaiters.append(continuation)
        }
    }

    func finishPreparation(
        with result: Result<Void, Error>
    ) {
        preparationContinuation?.resume(returning: result)
        preparationContinuation = nil
    }
}
