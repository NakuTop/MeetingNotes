import SwiftUI

@main
struct MeetingNotesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }

        Settings {
            Text("设置")
                .frame(width: 420, height: 240)
        }
    }
}
