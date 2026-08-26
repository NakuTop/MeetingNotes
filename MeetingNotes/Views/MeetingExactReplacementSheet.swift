import SwiftUI

struct MeetingExactReplacementSheet: View {
    @Bindable private var viewModel: MeetingDetailViewModel
    @State private var searchText: String
    @State private var replacementText = ""
    @State private var isPerforming = false

    let onClose: () -> Void

    init(
        viewModel: MeetingDetailViewModel,
        initialSearchText: String,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _searchText = State(initialValue: initialSearchText)
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AppWindowGlassBackground()
            AdaptiveGlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("替换本会议相同文字")
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("原文字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("要查找的文字", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(
                                "meeting.replacement.search"
                            )

                        Text("替换为")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("新文字", text: $replacementText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(
                                "meeting.replacement.replacement"
                            )
                    }

                    if let preview = currentPreview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("将替换 \(preview.totalMatches) 处")
                                .font(.callout.weight(.semibold))
                            replacementCount(
                                "完整转录",
                                count: preview.transcriptMatches,
                                identifier:
                                    "meeting.replacement.count.transcript"
                            )
                            replacementCount(
                                "说话人",
                                count: preview.speakerMatches,
                                identifier:
                                    "meeting.replacement.count.speaker"
                            )
                            replacementCount(
                                "重点总结",
                                count: preview.summaryMatches,
                                identifier:
                                    "meeting.replacement.count.summary"
                            )
                            replacementCount(
                                "完整纪要",
                                count: preview.detailedMinutesMatches,
                                identifier:
                                    "meeting.replacement.count.minutes"
                            )
                        }
                    }

                    if let message = viewModel.replacementErrorMessage {
                        Label(
                            message,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        Button("取消", role: .cancel) {
                            viewModel.cancelExactReplacement()
                            onClose()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(
                            "meeting.replacement.cancel"
                        )

                        Button("预览范围") {
                            previewReplacement()
                        }
                        .disabled(
                            isPerforming
                                || searchText.isEmpty
                                || searchText == replacementText
                        )
                        .accessibilityIdentifier(
                            "meeting.replacement.preview"
                        )

                        if let preview = currentPreview,
                           preview.totalMatches > 0 {
                            Button("确认替换", role: .destructive) {
                                confirmReplacement()
                            }
                            .disabled(isPerforming)
                            .accessibilityIdentifier(
                                "meeting.replacement.confirm"
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .frame(width: 480)
        .interactiveDismissDisabled(isPerforming)
    }

    private var currentPreview: MeetingExactReplacementPreview? {
        guard let preview = viewModel.replacementPreview,
              preview.searchText == searchText,
              preview.replacementText == replacementText else {
            return nil
        }
        return preview
    }

    private func replacementCount(
        _ title: String,
        count: Int,
        identifier: String
    ) -> some View {
        Text("\(title)：\(count) 处")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier)
    }

    private func previewReplacement() {
        guard !isPerforming else { return }
        isPerforming = true
        Task { @MainActor in
            await viewModel.prepareExactReplacement(
                searchText: searchText,
                replacementText: replacementText
            )
            isPerforming = false
        }
    }

    private func confirmReplacement() {
        guard !isPerforming else { return }
        isPerforming = true
        Task { @MainActor in
            let applied = await viewModel.confirmExactReplacement()
            isPerforming = false
            if applied {
                onClose()
            }
        }
    }
}
