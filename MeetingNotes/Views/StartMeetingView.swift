import SwiftUI

struct StartMeetingView: View {
    let viewModel: MeetingLibraryViewModel

    var body: some View {
        HStack(spacing: 16) {
            meetingButton(
                title: "线下会议",
                symbol: "person.2.fill",
                mode: .offline
            )
            meetingButton(
                title: "在线会议",
                symbol: "display",
                mode: .online
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityIdentifier("meeting.start")
    }

    private func meetingButton(
        title: String,
        symbol: String,
        mode: MeetingMode
    ) -> some View {
        Button {
            Task {
                await viewModel.startMeeting(mode: mode)
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 150, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isStarting)
        .keyboardShortcut(
            mode == .offline ? "1" : "2",
            modifiers: [.command]
        )
        .accessibilityIdentifier("meeting.start.\(mode.rawValue)")
    }
}
