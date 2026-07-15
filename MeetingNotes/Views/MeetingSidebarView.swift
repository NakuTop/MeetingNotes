import SwiftUI

struct MeetingSidebarView: View {
    @Bindable var viewModel: MeetingLibraryViewModel

    var body: some View {
        List(selection: $viewModel.selectedMeetingID) {
            ForEach(viewModel.meetings, id: \.id) { meeting in
                MeetingSidebarRow(meeting: meeting)
                    .tag(meeting.id)
                    .contextMenu {
                        Button("删除会议", role: .destructive) {
                            Task {
                                await viewModel.deleteMeeting(id: meeting.id)
                            }
                        }
                        .disabled(
                            viewModel.deletingMeetingIDs.contains(meeting.id)
                        )
                    }
            }
        }
        .navigationTitle("全部会议")
        .accessibilityIdentifier("meeting.sidebar")
    }
}

private struct MeetingSidebarRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)

            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Label(
                    meeting.mode == .offline ? "线下" : "在线",
                    systemImage: meeting.mode == .offline
                        ? "person.2.fill"
                        : "display"
                )
                Label(
                    MeetingDisplayFormat.duration(meeting.activeDuration),
                    systemImage: "clock"
                )
                Spacer(minLength: 0)
                Image(systemName: meeting.state == .archived
                    ? "checkmark.icloud.fill"
                    : "icloud.slash")
                    .foregroundStyle(
                        meeting.state == .archived ? .green : .secondary
                    )
                    .accessibilityLabel(
                        meeting.state == .archived ? "已归档" : "未归档"
                    )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(meeting.title)，\(meeting.mode == .offline ? "线下会议" : "在线会议")，\(MeetingDisplayFormat.duration(meeting.activeDuration))，\(meeting.state == .archived ? "已归档" : "未归档")"
        )
        .accessibilityIdentifier("meeting.historyRow")
    }
}
