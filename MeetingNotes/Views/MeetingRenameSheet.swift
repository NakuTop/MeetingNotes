import SwiftUI

struct MeetingRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MeetingLibraryViewModel

    let meetingID: UUID
    let originalTitle: String

    @State private var title: String
    @State private var isSubmitting = false
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
                    .disabled(isSubmitting)
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
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedTitle.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            let succeeded = await viewModel.renameMeeting(
                id: meetingID,
                title: trimmedTitle
            )
            isSubmitting = false
            if succeeded {
                dismiss()
            } else {
                isTitleFocused = true
            }
        }
    }

    private func cancel() {
        guard !isSubmitting else { return }
        title = originalTitle
        viewModel.dismissError()
        dismiss()
    }
}
