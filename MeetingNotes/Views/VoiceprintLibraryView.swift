import SwiftUI

struct VoiceprintLibraryView: View {
    @Bindable var model: VoiceprintPanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.selection == nil ? "本机声纹数据" : "本地声纹库")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.selection != nil {
                Toggle("启用本机姓名建议", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                Text("默认关闭。声纹加密保存在本机，不上传声纹或用于识别的音频。匹配只是建议，必须确认才会标注姓名；确认后的姓名按普通转录参与总结和同步。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("自动识别说话人不需要声纹库。在这里可删除之前录入的本机数据；会议录音、转录和已有姓名不受影响。")
                    .font(.callout).foregroundStyle(.secondary)
                if model.enabled {
                    Button("停用本机姓名建议") { model.setEnabled(false) }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selection = model.selection {
                        GroupBox("所选发言 · \(MeetingDisplayFormat.timecode(selection.start))") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("仅使用本段前 20 秒。请先听录音，选择至少 5 秒、无回声或重叠的清晰单人发言。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("查找姓名建议", systemImage: "person.crop.circle.badge.questionmark") { model.match() }
                                    .disabled(!model.enabled || !selection.canMatch || model.isWorking)
                                if let suggestion = model.suggestion {
                                    HStack {
                                        Text("待确认建议：\(suggestion.name)")
                                        Spacer()
                                        Button("确认用于本段") { model.confirmSuggestion() }
                                            .disabled(!model.enabled || model.isWorking)
                                    }
                                    Text("不是身份验证，可能匹配错误；请根据实际发言人确认。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                                TextField("录入姓名（仅用于本机声纹库）", text: $model.enrollmentName)
                                    .textFieldStyle(.roundedBorder)
                                Toggle("已征得发言人同意，并确认本段只有其一人清晰讲话", isOn: $model.enrollmentConsent)
                                    .font(.callout)
                                Button("录入本段声纹", systemImage: "person.crop.circle.badge.plus") { model.enroll() }
                                    .disabled(!model.enabled || !selection.canEnroll || !model.enrollmentConsent ||
                                        model.enrollmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                                if !selection.canEnroll {
                                    Text("录入前请先为本段指定正确的说话人。重叠发言、可能回声的段落不能用作声纹。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                    }
                    GroupBox("已录入 · \(model.profiles.count)") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.profiles.isEmpty { Text("尚无声纹").foregroundStyle(.secondary) }
                            ForEach(model.profiles) { profile in
                                HStack {
                                    Label(profile.name, systemImage: "person.wave.2")
                                    Spacer()
                                    Button("删除", role: .destructive) { model.delete(profile) }
                                        .disabled(model.isWorking)
                                }
                            }
                            Button("删除全部本机声纹…", role: .destructive) { confirmsDeletion = true }
                                .disabled(model.isWorking)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
            }
            if model.isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在本机处理…").font(.callout)
                    Spacer()
                    Button("取消本次操作") { model.cancel() }
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 540, height: model.selection == nil ? 430 : 650)
        .background(.regularMaterial)
        .task { model.load() }
        .onDisappear { model.cancel() }
        .confirmationDialog("删除全部本机声纹？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("删除全部声纹", role: .destructive) { model.deleteAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除声纹库，不删除会议录音、转录或已确认的姓名。")
        }
    }
}
