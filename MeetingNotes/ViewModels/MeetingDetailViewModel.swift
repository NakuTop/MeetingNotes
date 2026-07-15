import Foundation
import Observation

enum MeetingDetailPrimaryAction: Equatable, Sendable {
    case unavailable
    case summarizeAndArchive
    case summarizing
    case retryArchive
    case archiving
    case archived

    var title: String {
        switch self {
        case .unavailable: "总结并归档"
        case .summarizeAndArchive: "总结并归档"
        case .summarizing: "正在总结"
        case .retryArchive: "重试归档"
        case .archiving: "正在归档"
        case .archived: "已归档"
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable, .summarizeAndArchive: "sparkles"
        case .summarizing, .archiving: "clock.arrow.circlepath"
        case .retryArchive: "arrow.clockwise"
        case .archived: "checkmark.circle.fill"
        }
    }

    var isEnabled: Bool {
        self == .summarizeAndArchive || self == .retryArchive
    }
}

@MainActor
@Observable
final class MeetingDetailViewModel {
    let meetingID: UUID
    private let repository: MeetingRepository
    private let action: any SummarizeAndArchiving
    private let titleUpdater: any MeetingTitleUpdating

    private(set) var meeting: MeetingRecord?
    private(set) var isPerforming = false
    private(set) var operationState: RecordingState?
    private(set) var errorMessage: String?
    private(set) var isRenaming = false
    private(set) var renameErrorMessage: String?

    init(
        meetingID: UUID,
        repository: MeetingRepository,
        action: any SummarizeAndArchiving,
        titleUpdater: any MeetingTitleUpdating
    ) {
        self.meetingID = meetingID
        self.repository = repository
        self.action = action
        self.titleUpdater = titleUpdater
        meeting = try? repository.meeting(id: meetingID)
    }

    var primaryAction: MeetingDetailPrimaryAction {
        guard let state = meeting?.state else { return .unavailable }
        if isPerforming {
            return switch operationState ?? state {
            case .summaryReady, .archiving:
                .archiving
            case .archived:
                .archived
            default:
                .summarizing
            }
        }
        return switch state {
        case .ready: .summarizeAndArchive
        case .summarizing: .summarizing
        case .summaryReady: .retryArchive
        case .archiving: .archiving
        case .archived: .archived
        default: .unavailable
        }
    }

    func load() {
        do {
            meeting = try repository.meeting(id: meetingID)
        } catch {
            meeting = nil
            errorMessage = "无法加载会议详情。"
        }
    }

    func performPrimaryAction() async {
        guard primaryAction.isEnabled, !isPerforming else { return }
        isPerforming = true
        operationState = meeting?.state
        errorMessage = nil
        defer {
            isPerforming = false
            operationState = nil
        }

        do {
            try await action.execute(meetingID: meetingID) { [weak self] state in
                self?.operationState = state
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        load()
    }

    func dismissError() {
        errorMessage = nil
    }

    func rename(to title: String) async -> Bool {
        guard !isRenaming else { return false }
        isRenaming = true
        renameErrorMessage = nil
        defer { isRenaming = false }

        do {
            try await titleUpdater.updateTitle(
                meetingID: meetingID,
                title: title
            )
            load()
            return true
        } catch let error as MeetingTitleUpdateError {
            renameErrorMessage = error.userMessage
            return false
        } catch {
            renameErrorMessage = "无法重命名会议，请稍后重试。"
            return false
        }
    }

    func dismissRenameError() {
        renameErrorMessage = nil
    }

    private static func message(for error: Error) -> String {
        switch error as? SummarizeAndArchiveError {
        case .noFinalTranscript:
            "没有可用的最终转录，暂时无法总结。"
        case .missingDeepSeekCredential:
            "请先在设置中保存 DeepSeek API Key。"
        case .missingNotionCredential:
            "总结已保存在本机。请在设置中保存 Notion Token 后重试归档。"
        case .invalidNotionPageURL:
            "总结已保存在本机。请在设置中填写有效的 Notion 父页面链接。"
        case .summaryFailed:
            "DeepSeek 总结失败，会议记录仍保存在本机，请稍后重试。"
        case .archiveFailed:
            "Notion 归档失败，可直接重试，不会再次生成总结。"
        case .localPersistenceFailed:
            "无法保存本地总结，请检查磁盘空间后重试。"
        case .operationInProgress:
            "会议正在处理中，请稍候。"
        case .missingLocalSummary:
            "找不到本地总结，请重新生成。"
        case .invalidState:
            "当前会议状态不能执行该操作。"
        case nil:
            "操作失败，请稍后重试。"
        }
    }
}

extension MeetingTitleUpdateError {
    var userMessage: String {
        switch self {
        case .emptyTitle:
            "会议标题不能为空。"
        case .operationInProgress:
            "正在重命名该会议，请稍候。"
        case .missingNotionCredential:
            "请先在设置中保存 Notion Token，再重试重命名。"
        case .missingNotionPage:
            "找不到该会议对应的 Notion 页面，无法同步标题。"
        case .credentialAccessFailed:
            "无法读取 Notion Token，请重新保存后重试。"
        case .localUpdateFailed:
            "无法保存会议标题，请检查本地存储后重试。"
        case .invalidState:
            "会议正在总结或归档，暂时不能重命名。"
        case let .notion(error):
            switch error {
            case .unauthorized:
                "Notion Token 无效，请在设置中重新保存。"
            case .forbidden:
                "Notion 集成无权修改该页面，请检查页面共享权限。"
            case .pageNotFound:
                "找不到对应的 Notion 页面，请检查页面是否仍存在并已共享。"
            case .rateLimited:
                "Notion 请求过于频繁，请稍后重试。"
            case .timeout:
                "连接 Notion 超时，请检查网络后重试。"
            case .transport:
                "无法连接 Notion，请检查网络后重试。"
            case .server, .http:
                "Notion 服务暂时无法更新标题，请稍后重试。"
            case .invalidRequest:
                "Notion 拒绝了标题更新请求，请检查页面状态。"
            case .invalidResponse:
                "Notion 返回异常响应，请稍后重试。"
            }
        }
    }
}
