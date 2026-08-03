import Foundation

enum MeetingNotionArchiveDisplayState: Equatable, Sendable {
    case none
    case partial
    case complete

    static func resolve(
        summary: MeetingDocumentArchiveState?,
        detailedMinutes: MeetingDocumentArchiveState?,
        legacyMeetingState: RecordingState,
        hasNotionPage: Bool
    ) -> Self {
        let states = [summary, detailedMinutes].compactMap { $0 }
        guard !states.isEmpty else {
            return legacyMeetingState == .archived && hasNotionPage
                ? .complete
                : .none
        }

        let archivedCount = states.filter { $0 == .archived }.count
        guard archivedCount > 0 else { return .none }
        return archivedCount == states.count ? .complete : .partial
    }

    var symbolName: String {
        switch self {
        case .none: "icloud.slash"
        case .partial: "checkmark.icloud"
        case .complete: "checkmark.icloud.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .none: "未归档到 Notion"
        case .partial: "部分内容已归档到 Notion"
        case .complete: "全部内容已归档到 Notion"
        }
    }
}
