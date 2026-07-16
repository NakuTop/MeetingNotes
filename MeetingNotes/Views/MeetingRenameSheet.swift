import SwiftUI

struct MeetingRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MeetingLibraryViewModel

    let meetingID: UUID
    let originalTitle: String

    @State private var title: String
    @State private var isSubmitting = false
    @State private var renameTask: Task<Void, Never>?
    @State private var renameGeneration = 0
    @FocusState private var isTitleFocused: Bool

    init(
        meetingID: UUID,
        originalTitle: String,
        viewModel: MeetingLibraryViewModel
    ) {
        self.meetingID = meetingID
        self.originalTitle = originalTitle
        self.viewModel = viewModel
        _title = State(initialValue: originalTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("重命名会议")
                    .font(.title2.bold())
                Text("已归档会议会同步更新 Notion 页面标题。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("会议标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .onSubmit(submit)
                .onExitCommand(perform: cancel)
                .disabled(isSubmitting)
                .accessibilityIdentifier("meeting.rename.field")

            if let errorMessage = viewModel.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("meeting.rename.cancel")

                Button(action: submit) {
                    HStack(spacing: 7) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("保存")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || isSubmitting)
                .accessibilityIdentifier("meeting.rename.save")
            }
        }
        .padding(24)
        .frame(width: 430)
        .onAppear {
            viewModel.dismissError()
            Task { @MainActor in
                await Task.yield()
                isTitleFocused = true
            }
        }
        .onDisappear {
            invalidateRenameTask(resetDraft: true)
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedTitle.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        renameGeneration &+= 1
        let generation = renameGeneration
        let submittedMeetingID = meetingID
        let submittedTitle = trimmedTitle
        renameTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let succeeded = await viewModel.renameMeeting(
                id: submittedMeetingID,
                title: submittedTitle
            )
            guard !Task.isCancelled,
                  generation == renameGeneration,
                  submittedMeetingID == meetingID else {
                return
            }
            renameTask = nil
            isSubmitting = false
            if succeeded {
                dismiss()
            } else {
                isTitleFocused = true
            }
        }
    }

    private func cancel() {
        invalidateRenameTask(resetDraft: true)
        dismiss()
    }

    private func invalidateRenameTask(resetDraft: Bool) {
        renameGeneration &+= 1
        renameTask?.cancel()
        renameTask = nil
        isSubmitting = false
        isTitleFocused = false
        if resetDraft {
            title = originalTitle
        }
        viewModel.dismissError()
    }
}
