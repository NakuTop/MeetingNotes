import SwiftUI

@main
struct MeetingNotesApp: App {
    private enum StartupState {
        case ready(AppContainer)
        case failed
    }

    private let startupState: StartupState

    init() {
        do {
            startupState = .ready(try AppContainer.live())
        } catch {
            startupState = .failed
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startupState {
            case let .ready(container):
                RootView(
                    viewModel: container.libraryViewModel,
                    requestSummary: { meetingID in
                        container.requestSummary(for: meetingID)
                    }
                )
            case .failed:
                ContentUnavailableView(
                    "无法打开会议数据库",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(
                        "本地数据未被修改。请确认磁盘空间后重新打开应用。"
                    )
                )
                .frame(minWidth: 640, minHeight: 420)
            }
        }

        Settings {
            Text("设置")
                .frame(width: 420, height: 240)
        }
    }
}
