import Foundation

enum MeetingNotionArchiveDisplayState: Equatable, Sendable {
    case none
    case dirty
    case syncing
    case failed
    case complete

    static func resolve(
        notionSyncStateRawValue: String?,
        contentRevision: Int,
        syncedContentRevision: Int?,
        summary: MeetingDocumentArchiveState?,
        detailedMinutes: MeetingDocumentArchiveState?,
        legacyMeetingState: RecordingState,
        hasNotionPage: Bool
    ) -> Self {
        guard hasNotionPage else { return .none }
        if let notionSyncStateRawValue,
           let syncState = MeetingNotionSyncState(
               rawValue: notionSyncStateRawValue
           ) {
            switch syncState {
            case .syncing:
                return .syncing
            case .failed:
                return .failed
            case .synced:
                guard let syncedContentRevision else { return .none }
                return syncedContentRevision == contentRevision
                    ? .complete
                    : .dirty
            case .localOnly:
                return syncedContentRevision == nil ? .none : .dirty
            }
        }

        return legacyState(
            summary: summary,
            detailedMinutes: detailedMinutes,
            legacyMeetingState: legacyMeetingState
        )
    }

    private static func legacyState(
        summary: MeetingDocumentArchiveState?,
        detailedMinutes: MeetingDocumentArchiveState?,
        legacyMeetingState: RecordingState
    ) -> Self {
        let states = [summary, detailedMinutes].compactMap { $0 }
        guard !states.isEmpty else {
            return legacyMeetingState == .archived
                ? .complete
                : .none
        }

        let archivedCount = states.filter { $0 == .archived }.count
        guard archivedCount > 0 else { return .none }
        return archivedCount == states.count ? .complete : .dirty
    }

    var symbolName: String {
        switch self {
        case .none: "icloud.slash"
        case .dirty: "icloud.and.arrow.up"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        case .complete: "checkmark.icloud.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .none: "尚未同步到 Notion"
        case .dirty: "有本地更改待同步到 Notion"
        case .syncing: "正在同步到 Notion"
        case .failed: "同步到 Notion 失败"
        case .complete: "已同步到 Notion"
        }
    }
}
