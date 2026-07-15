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
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
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
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
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
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
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
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
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

    func testRenameTracksProgressReloadsTitleAndReturnsTrue() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let updater = BlockingDetailTitleUpdater { _, title in
            try repository.updateTitle(meetingID: meetingID, title: title)
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: DetailActionSpy(),
            titleUpdater: updater
        )

        let operation = Task {
            await viewModel.rename(to: "新会议标题")
        }
        await updater.waitUntilStarted()

        XCTAssertTrue(viewModel.isRenaming)
        updater.finish()
        let succeeded = await operation.value

        XCTAssertTrue(succeeded)
        XCTAssertFalse(viewModel.isRenaming)
        XCTAssertEqual(viewModel.meeting?.title, "新会议标题")
        XCTAssertNil(viewModel.renameErrorMessage)
    }

    func testRenameErrorsUseIndependentChannelAndMapActionableMessages() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let cases: [(MeetingTitleUpdateError, String)] = [
            (.emptyTitle, "会议标题不能为空。"),
            (.operationInProgress, "正在重命名该会议，请稍候。"),
            (
                .missingNotionCredential,
                "请先在设置中保存 Notion Token，再重试重命名。"
            ),
            (
                .missingNotionPage,
                "找不到该会议对应的 Notion 页面，无法同步标题。"
            ),
            (
                .credentialAccessFailed,
                "无法读取 Notion Token，请重新保存后重试。"
            ),
            (
                .invalidState(.summarizing),
                "会议正在总结或归档，暂时不能重命名。"
            ),
            (
                .localUpdateFailed,
                "无法保存会议标题，请检查本地存储后重试。"
            ),
            (
                .notion(.unauthorized),
                "Notion Token 无效，请在设置中重新保存。"
            ),
            (
                .notion(.forbidden),
                "Notion 集成无权修改该页面，请检查页面共享权限。"
            ),
            (
                .notion(.pageNotFound),
                "找不到对应的 Notion 页面，请检查页面是否仍存在并已共享。"
            ),
            (
                .notion(.rateLimited),
                "Notion 请求过于频繁，请稍后重试。"
            ),
            (
                .notion(.timeout),
                "连接 Notion 超时，请检查网络后重试。"
            ),
            (
                .notion(.transport),
                "无法连接 Notion，请检查网络后重试。"
            )
        ]

        for (error, expectedMessage) in cases {
            let updater = DetailTitleUpdaterSpy(error: error)
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                action: DetailActionSpy(),
                titleUpdater: updater
            )

            let succeeded = await viewModel.rename(to: "新标题")

            XCTAssertFalse(succeeded, "Expected \(error) to fail")
            XCTAssertEqual(
                viewModel.renameErrorMessage,
                expectedMessage,
                "Unexpected message for \(error)"
            )
            XCTAssertNil(viewModel.errorMessage)
            viewModel.dismissRenameError()
            XCTAssertNil(viewModel.renameErrorMessage)
        }
    }

    func testRenameDoesNotSubmitTwiceWhileRequestIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let updater = BlockingDetailTitleUpdater()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: DetailActionSpy(),
            titleUpdater: updater
        )

        let first = Task { await viewModel.rename(to: "第一个标题") }
        await updater.waitUntilStarted()
        let secondSucceeded = await viewModel.rename(to: "第二个标题")

        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(updater.requests.count, 1)
        updater.finish()
        _ = await first.value
    }

    func testPrimaryActionDoesNotStartWhileRenameIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let updater = BlockingDetailTitleUpdater()
        let action = DetailActionSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action,
            titleUpdater: updater
        )
        let rename = Task { await viewModel.rename(to: "新标题") }
        await updater.waitUntilStarted()

        await viewModel.performPrimaryAction()

        XCTAssertEqual(action.callCount, 0)
        updater.finish()
        _ = await rename.value
    }

    func testRenameDoesNotStartWhilePrimaryActionIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = BlockingDetailAction()
        let updater = DetailTitleUpdaterSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: action,
            titleUpdater: updater
        )
        let primaryAction = Task { await viewModel.performPrimaryAction() }
        await action.waitUntilStarted()

        let succeeded = await viewModel.rename(to: "新标题")

        XCTAssertFalse(succeeded)
        XCTAssertTrue(updater.requests.isEmpty)
        action.finish()
        _ = await primaryAction.value
    }
}

private struct TitleUpdateRequest: Equatable {
    let meetingID: UUID
    let title: String
}

@MainActor
private final class DetailTitleUpdaterSpy: MeetingTitleUpdating {
    private let error: Error?
    private(set) var requests: [TitleUpdateRequest] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func updateTitle(meetingID: UUID, title: String) async throws {
        requests.append(TitleUpdateRequest(meetingID: meetingID, title: title))
        if let error { throw error }
    }
}

@MainActor
private final class BlockingDetailTitleUpdater: MeetingTitleUpdating {
    private let onFinish: (UUID, String) throws -> Void
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [TitleUpdateRequest] = []

    init(onFinish: @escaping (UUID, String) throws -> Void = { _, _ in }) {
        self.onFinish = onFinish
    }

    func updateTitle(meetingID: UUID, title: String) async throws {
        requests.append(TitleUpdateRequest(meetingID: meetingID, title: title))
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        try onFinish(meetingID, title)
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
