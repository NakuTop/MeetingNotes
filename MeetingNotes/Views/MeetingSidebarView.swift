import SwiftUI

struct MeetingSidebarView: View {
    @Bindable var viewModel: MeetingLibraryViewModel
    @State private var pendingDeletionID: UUID?
    @State private var renameRequest: RenameRequest?

    var body: some View {
        List(selection: $viewModel.selectedMeetingID) {
            ForEach(viewModel.meetings, id: \.id) { meeting in
                MeetingSidebarRow(meeting: meeting)
                    .tag(meeting.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            viewModel.togglePinned(id: meeting.id)
                        } label: {
                            Label(
                                meeting.isPinned ? "取消置顶" : "置顶会议",
                                systemImage: meeting.isPinned
                                    ? "pin.slash"
                                    : "pin.fill"
                            )
                        }
                        .tint(.orange)
                        .disabled(isPinning(meeting))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletionID = meeting.id
                        } label: {
                            Label("删除会议", systemImage: "trash")
                        }
                        .disabled(!canDelete(meeting))
                    }
                    .contextMenu {
                        Button("重命名") {
                            renameRequest = RenameRequest(meeting: meeting)
                        }
                        .disabled(!canRename(meeting))
                        .accessibilityIdentifier("meeting.context.rename")

                        Button(meeting.isPinned ? "取消置顶" : "置顶会议") {
                            viewModel.togglePinned(id: meeting.id)
                        }
                        .disabled(isPinning(meeting))
                        .accessibilityIdentifier("meeting.context.pin")

                        Divider()

                        Button("删除会议", role: .destructive) {
                            pendingDeletionID = meeting.id
                        }
                        .disabled(!canDelete(meeting))
                        .accessibilityIdentifier("meeting.context.delete")
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
        .navigationTitle("全部会议")
        .accessibilityIdentifier("meeting.sidebar")
        .sheet(item: $renameRequest) { request in
            MeetingRenameSheet(
                meetingID: request.id,
                originalTitle: request.title,
                viewModel: viewModel
            )
        }
        .confirmationDialog(
            "删除这场会议？",
            isPresented: deletionDialogPresented,
            titleVisibility: .visible
        ) {
            Button("删除会议", role: .destructive) {
                guard let pendingDeletionID else { return }
                self.pendingDeletionID = nil
                Task {
                    await viewModel.deleteMeeting(id: pendingDeletionID)
                }
            }
            .accessibilityIdentifier("meeting.delete.confirm")

            Button("取消", role: .cancel) {
                pendingDeletionID = nil
            }
            .accessibilityIdentifier("meeting.delete.cancel")
        } message: {
            Text("本地录音、转录和总结将被永久删除，Notion 页面不会被删除。")
        }
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletionID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionID = nil
                }
            }
        )
    }

    private func canDelete(_ meeting: MeetingRecord) -> Bool {
        viewModel.canDelete(meeting)
            && !viewModel.deletingMeetingIDs.contains(meeting.id)
    }

    private func canRename(_ meeting: MeetingRecord) -> Bool {
        viewModel.canRename(meeting)
            && !viewModel.renamingMeetingIDs.contains(meeting.id)
    }

    private func isPinning(_ meeting: MeetingRecord) -> Bool {
        viewModel.pinningMeetingIDs.contains(meeting.id)
    }
}

private struct RenameRequest: Identifiable {
    let id: UUID
    let title: String

    init(meeting: MeetingRecord) {
        id = meeting.id
        title = meeting.title
    }
}

private struct MeetingSidebarRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if meeting.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
            }

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
            "\(meeting.title)，\(meeting.isPinned ? "已置顶" : "未置顶")，\(meeting.mode == .offline ? "线下会议" : "在线会议")，\(MeetingDisplayFormat.duration(meeting.activeDuration))，\(meeting.state == .archived ? "已归档" : "未归档")"
        )
        .accessibilityValue(
            "\(meeting.id.uuidString)，\(meeting.isPinned ? "已置顶" : "未置顶")"
        )
        .accessibilityIdentifier("meeting.historyRow")
    }
}
