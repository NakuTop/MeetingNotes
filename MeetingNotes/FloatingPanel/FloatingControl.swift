import Foundation

struct FloatingControlPresentation: Equatable, Sendable {
    let symbolName: String
    let accessibilityLabel: String
}

enum FloatingControl: String, CaseIterable, Identifiable, Sendable {
    case record
    case pause
    case stop
    case bookmark

    var id: Self { self }

    func presentation(isPaused: Bool) -> FloatingControlPresentation {
        switch self {
        case .record:
            FloatingControlPresentation(
                symbolName: "record.circle.fill",
                accessibilityLabel: "录音中"
            )
        case .pause:
            FloatingControlPresentation(
                symbolName: isPaused ? "play.fill" : "pause.fill",
                accessibilityLabel: isPaused ? "继续" : "暂停"
            )
        case .stop:
            FloatingControlPresentation(
                symbolName: "stop.fill",
                accessibilityLabel: "结束"
            )
        case .bookmark:
            FloatingControlPresentation(
                symbolName: "bookmark.fill",
                accessibilityLabel: "书签"
            )
        }
    }
}
