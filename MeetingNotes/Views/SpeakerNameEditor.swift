import SwiftUI

struct SpeakerNameEditor: View {
    let currentName: String
    let frequentNames: [String]
    let canRestoreDefault: Bool
    let errorMessage: String?
    let onSave: (String) -> Void
    let onRestoreDefault: () -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        currentName: String,
        frequentNames: [String],
        canRestoreDefault: Bool,
        errorMessage: String?,
        onSave: @escaping (String) -> Void,
        onRestoreDefault: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentName = currentName
        self.frequentNames = frequentNames
        self.canRestoreDefault = canRestoreDefault
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onRestoreDefault = onRestoreDefault
        self.onCancel = onCancel
        _draft = State(initialValue: currentName)
    }

    private var normalizedDraft: String? {
        AppSettingsStore.normalizedSpeakerNames([draft]).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改说话人名称")
                .font(.headline)

            TextField("姓名或角色", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
                .accessibilityIdentifier("speaker.editor.name")

            if !frequentNames.isEmpty {
                Text("常用名称")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), spacing: 7)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(frequentNames, id: \.self) { name in
                        Button(name) {
                            draft = name
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                if canRestoreDefault {
                    Button("恢复默认") {
                        onRestoreDefault()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("取消", action: onCancel)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedDraft == nil)
                    .accessibilityIdentifier("speaker.editor.save")
            }
        }
        .padding(18)
        .frame(width: 330)
        .onAppear {
            isFocused = true
        }
    }

    private func save() {
        guard let normalizedDraft else { return }
        onSave(normalizedDraft)
    }
}
