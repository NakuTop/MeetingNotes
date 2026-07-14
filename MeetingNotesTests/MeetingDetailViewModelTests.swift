import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingDetailViewModelTests: XCTestCase {
    func testPrimaryButtonReflectsWorkflowState() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let action = DetailActionSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action
        )

        let cases: [(RecordingState, MeetingDetailPrimaryAction)] = [
            (.recording, .unavailable),
            (.ready, .summarizeAndArchive),
            (.summarizing, .summarizing),
            (.summaryReady, .retryArchive),
            (.archiving, .archiving),
            (.archived, .archived)
        ]

        for (state, expected) in cases {
            try repository.updateMeetingState(id: meetingID, state: state)
            viewModel.load()
            XCTAssertEqual(viewModel.primaryAction, expected)
        }
    }

    func testArchiveFailureReloadsSummaryReadyAndShowsRetryMessage() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = DetailActionSpy(
            execute: {
                try repository.updateMeetingState(
                    id: meetingID,
                    state: .summaryReady
                )
                throw SummarizeAndArchiveError.archiveFailed
            }
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action
        )

        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.primaryAction, .retryArchive)
        XCTAssertEqual(viewModel.errorMessage, "Notion 归档失败，可直接重试，不会再次生成总结。")
        XCTAssertEqual(action.callCount, 1)
    }

    func testActionImmediatelyShowsSummarizingWhileRequestIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = BlockingDetailAction()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action
        )

        let operation = Task {
            await viewModel.performPrimaryAction()
        }
        await action.waitUntilStarted()

        XCTAssertEqual(viewModel.primaryAction, .summarizing)
        XCTAssertTrue(viewModel.isPerforming)

        action.finish()
        await operation.value
    }

    func testActionShowsArchivingWhenWorkflowReportsTransition() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = ProgressingDetailAction()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action
        )

        let operation = Task {
            await viewModel.performPrimaryAction()
        }
        await action.waitUntilStarted()

        XCTAssertEqual(viewModel.primaryAction, .archiving)
        XCTAssertTrue(viewModel.isPerforming)

        action.finish()
        await operation.value
    }
}

@MainActor
private final class DetailActionSpy: SummarizeAndArchiving {
    private let executeBlock: () async throws -> Void
    private(set) var callCount = 0

    init(execute: @escaping () async throws -> Void = {}) {
        executeBlock = execute
    }

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        callCount += 1
        try await executeBlock()
    }
}

@MainActor
private final class BlockingDetailAction: SummarizeAndArchiving {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class ProgressingDetailAction: SummarizeAndArchiving {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        await waitForFinish()
    }

    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws {
        _ = meetingID
        onProgress(.archiving)
        await waitForFinish()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func waitForFinish() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }
}
