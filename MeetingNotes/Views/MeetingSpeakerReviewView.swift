import SwiftUI

struct MeetingSpeakerReviewView: View {
    @Bindable var viewModel: MeetingDetailViewModel
    let canPreview: Bool
    let onPreview: (Double, Double) -> Void
    let onStopPreview: () -> Void
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: MeetingSpeakerReviewCatalog?
    @State private var selectedGroupID = ""
    @State private var targetSpeakerID = ""
    @State private var selectedItems: Set<UUID> = []
    @State private var notice: String?

    private var group: SpeakerReviewGroup? { catalog?.groups.first { $0.id == selectedGroupID } }
    private var selectedRows: [SpeakerReviewRowSnapshot] {
        group?.items.filter { selectedItems.contains($0.id) }.flatMap(\.rows) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("复核说话人").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("按候选人集中试听、勾选后确认。相似不代表同一人；只修改选中的片段，人工标注始终优先。")
                .font(.callout).foregroundStyle(.secondary)
            if let catalog {
                if !catalog.groups.isEmpty {
                    HStack {
                        Picker("候选分组", selection: $selectedGroupID) {
                            ForEach(catalog.groups) { group in
                                Text("候选 \(label(group.id)) · \(group.items.count) 段").tag(group.id)
                            }
                        }
                        Button("刷新") { refresh() }.buttonStyle(.borderless)
                    }
                    if let group {
                        HStack {
                            Button("全选本组") { selectedItems = Set(group.items.map(\.id)) }
                            Button("清空选择") { selectedItems = [] }
                            Spacer()
                            Button("停止试听", systemImage: "pause.fill", action: onStopPreview)
                        }
                        .buttonStyle(.borderless).font(.callout)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(group.items) { item in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle(isOn: Binding(get: { selectedItems.contains(item.id) }, set: {
                                            if $0 { selectedItems.insert(item.id) } else { selectedItems.remove(item.id) }
                                        })) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(MeetingDisplayFormat.timecode(item.start)).font(.caption.monospacedDigit())
                                                Text(item.text).font(.body).fixedSize(horizontal: false, vertical: true)
                                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.toggleStyle(.checkbox)
                                        Spacer(minLength: 0)
                                        Button { onPreview(item.start, item.end) } label: {
                                            Image(systemName: "play.circle")
                                        }
                                        .buttonStyle(.borderless).disabled(!canPreview)
                                        .help("试听本段附近的录音，最多 12 秒")
                                        .accessibilityLabel("试听 \(MeetingDisplayFormat.timecode(item.start))")
                                    }
                                    .padding(10)
                                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        HStack {
                            Picker("确认为", selection: $targetSpeakerID) {
                                ForEach(catalog.speakerIDs, id: \.self) { id in Text(label(id)).tag(id) }
                            }.frame(maxWidth: 250)
                            Spacer()
                            Button("确认所选 \(selectedItems.count) 段") {
                                onStopPreview()
                                let count = selectedItems.count
                                if viewModel.confirmSpeakerReview(selectedRows, speakerID: targetSpeakerID) {
                                    notice = "已确认 \(count) 段；可撤销最近一次批量操作。"
                                    onChanged()
                                    refresh()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedRows.isEmpty || targetSpeakerID.isEmpty)
                        }
                    }
                } else {
                    ContentUnavailableView(catalog.totalUncertainCount == 0 ? "暂无待复核的片段" : "暂时没有可安全分组的候选",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("可先使用“校准说话人”进行本地复核；也可直接点击转录里的标签，逐段指定或新增说话人。"))
                }
                if catalog.ungroupedCount > 0 {
                    Text("另有 \(catalog.ungroupedCount) 段重叠或证据不足，未混入上述分组；仍保留在转录中供逐段判断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { ProgressView() }
            if !canPreview { Text("会议录音尚未就绪，暂不可试听。").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("撤销最近一次批量确认", systemImage: "arrow.uturn.backward") {
                    if viewModel.undoSpeakerReview() { notice = "已恢复原来的待确认状态。"; onChanged(); refresh() }
                }.disabled(!viewModel.canUndoSpeakerReview)
                Spacer()
                Text("只在本机分析，不上传用于识别的音频或声纹").font(.caption).foregroundStyle(.secondary)
            }
            if let error = viewModel.speakerReviewErrorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            else if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(24).frame(width: 680, height: 650).background(.regularMaterial)
        .task {
            await viewModel.flushEdits()
            viewModel.dismissSpeakerReviewError()
            refresh()
        }
        .onChange(of: selectedGroupID) { _, id in
            selectedItems = []
            targetSpeakerID = id
            onStopPreview()
        }
        .onDisappear(perform: onStopPreview)
    }

    private func refresh() {
        catalog = viewModel.speakerReviewCatalog()
        selectedItems = []
        if catalog?.groups.contains(where: { $0.id == selectedGroupID }) != true {
            selectedGroupID = catalog?.groups.first?.id ?? ""
        }
        targetSpeakerID = selectedGroupID
    }

    private func label(_ id: String) -> String {
        TranscriptSpeakerLabelPolicy.label(speakerID: id,
            source: id.hasPrefix("room-") ? .room : (id.hasPrefix("remote-") ? .system : .mixed),
            customNames: viewModel.speakerDisplayNames) ?? id
    }
}
