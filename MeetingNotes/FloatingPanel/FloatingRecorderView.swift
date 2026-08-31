import SwiftUI

struct FloatingRecorderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNoteFieldFocused: Bool

    let isPaused: Bool
    let recordingPresentationStore: RecordingSessionPresentationStore
    let annotationViewModel: RecordingAnnotationViewModel
    let action: (FloatingControl) -> Void
    let noteEditorPresentationChanged: (Bool) -> Void
    let screenshotFeedbackPresentationChanged: (Bool) -> Void
    let controls = FloatingControl.allCases

    init(
        isPaused: Bool,
        recordingPresentationStore: RecordingSessionPresentationStore,
        annotationViewModel: RecordingAnnotationViewModel,
        action: @escaping (FloatingControl) -> Void,
        noteEditorPresentationChanged: @escaping (Bool) -> Void = { _ in },
        screenshotFeedbackPresentationChanged:
            @escaping (Bool) -> Void = { _ in }
    ) {
        self.isPaused = isPaused
        self.recordingPresentationStore = recordingPresentationStore
        self.annotationViewModel = annotationViewModel
        self.action = action
        self.noteEditorPresentationChanged = noteEditorPresentationChanged
        self.screenshotFeedbackPresentationChanged =
            screenshotFeedbackPresentationChanged
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 6) {
                        controlsRow(liquidGlass: true)
                            .padding(8)
                            .glassEffect(.regular, in: Capsule())

                        if annotationViewModel.isNoteEditorPresented {
                            noteEditor
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .glassEffect(
                                    .regular,
                                    in: RoundedRectangle(cornerRadius: 15)
                                )
                        }

                        if isScreenshotFeedbackPresented {
                            screenshotFeedback
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .glassEffect(
                                    .regular,
                                    in: RoundedRectangle(cornerRadius: 15)
                                )
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    controlsRow(liquidGlass: false)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.16), lineWidth: 0.5)
                        }

                    if annotationViewModel.isNoteEditorPresented {
                        noteEditor
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 15)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(
                                        .white.opacity(0.16),
                                        lineWidth: 0.5
                                    )
                            }
                    }

                    if isScreenshotFeedbackPresented {
                        screenshotFeedback
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 15)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(
                                        .white.opacity(0.16),
                                        lineWidth: 0.5
                                    )
                            }
                    }
                }
            }
        }
        .padding(1)
        .animation(
            AppVisualPolicy.motion(reduceMotion: reduceMotion).animation,
            value: isPaused
        )
        .onChange(of: annotationViewModel.isNoteEditorPresented) {
            _, isPresented in
            noteEditorPresentationChanged(isPresented)
            isNoteFieldFocused = isPresented
        }
        .onChange(of: annotationViewModel.screenshotState) { _, _ in
            screenshotFeedbackPresentationChanged(
                isScreenshotFeedbackPresented
            )
        }
        .onAppear {
            isNoteFieldFocused = annotationViewModel.isNoteEditorPresented
            screenshotFeedbackPresentationChanged(
                isScreenshotFeedbackPresented
            )
        }
    }

    private func controlsRow(liquidGlass: Bool) -> some View {
        HStack(spacing: 8) {
            elapsedDisplay

            Divider()
                .frame(height: 24)
                .opacity(0.45)

            ForEach(controls) { control in
                controlButton(control, liquidGlass: liquidGlass)
            }
        }
    }

    private var elapsedDisplay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(statusOpacity(at: context.date))

                Text(
                    elapsedText(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                )
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .contentTransition(.numericText())
                .frame(minWidth: 46, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(statusAccessibilityLabel) \(elapsedText(at: ProcessInfo.processInfo.systemUptime))"
            )
            .accessibilityIdentifier("floating.elapsed")
        }
    }

    private var noteEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.blue)

            TextField(
                "输入笔记，按 Return 完成",
                text: Binding(
                    get: { annotationViewModel.noteDraft },
                    set: { annotationViewModel.updateNoteDraft($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isNoteFieldFocused)
            .onSubmit {
                Task { await submitNote() }
            }
            .accessibilityIdentifier("floating.noteField")

            noteSaveIndicator
        }
        .frame(height: 24)
    }

    var isScreenshotFeedbackPresented: Bool {
        switch annotationViewModel.screenshotState {
        case .permissionRequired, .failed:
            true
        case .idle, .capturing, .saved:
            false
        }
    }

    @ViewBuilder
    private var screenshotFeedback: some View {
        HStack(spacing: 8) {
            switch annotationViewModel.screenshotState {
            case .permissionRequired:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("需要屏幕录制权限才能保存截图")
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("打开设置") {
                    try? PrivacySettingsOpener().open(.screenRecording)
                }
                .controlSize(.small)
                .accessibilityIdentifier("floating.screenshot.openSettings")
            case let .failed(message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 4)
            case .idle, .capturing, .saved:
                EmptyView()
            }

            Button {
                annotationViewModel.dismissScreenshotFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭截图提示")
            .accessibilityIdentifier("floating.screenshot.dismissFeedback")
        }
        .frame(minHeight: 24)
        .accessibilityIdentifier("floating.screenshot.feedback")
    }

    @ViewBuilder
    private var noteSaveIndicator: some View {
        switch annotationViewModel.noteSaveState {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("正在保存笔记")
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("笔记已保存")
        case .failed:
            Button {
                Task { await annotationViewModel.retryNoteSave() }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试保存笔记")
        }
    }

    func submitNote() async {
        await annotationViewModel.submitNote()
        if !annotationViewModel.isNoteEditorPresented {
            isNoteFieldFocused = false
        }
    }

    func elapsedText(at monotonicTime: TimeInterval) -> String {
        guard let meetingID = recordingPresentationStore.meetingID else {
            return MeetingDisplayFormat.duration(0)
        }
        return MeetingDisplayFormat.duration(
            recordingPresentationStore.activeDuration(
                for: meetingID,
                at: monotonicTime
            ) ?? 0
        )
    }

    private var presentationPhase: RecordingSessionPresentationPhase {
        recordingPresentationStore.phase ?? (isPaused ? .paused : .recording)
    }

    private var statusColor: Color {
        presentationPhase == .paused ? .orange : .red
    }

    var statusAccessibilityLabel: String {
        switch presentationPhase {
        case .recording: "正在录音"
        case .paused: "录音已暂停"
        case .finished: "录音已结束"
        }
    }

    private func statusOpacity(at date: Date) -> Double {
        guard presentationPhase == .recording, !reduceMotion else {
            return 1
        }
        return Int(date.timeIntervalSinceReferenceDate) % 2 == 0
            ? 1
            : 0.42
    }

    @ViewBuilder
    private func controlButton(
        _ control: FloatingControl,
        liquidGlass: Bool
    ) -> some View {
        let presentation = control.presentation(isPaused: isPaused)
        let isEnabled = isControlEnabled(control)
        let button = Button {
            action(control)
        } label: {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
                .contentTransition(
                    reduceMotion ? .identity : .symbolEffect(.replace)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle(for: control))
        .disabled(!isEnabled)
        .opacity(control == .record && isPaused ? 0.45 : 1)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .accessibilityIdentifier("floating.\(control.rawValue)")

        if #available(macOS 26.0, *), liquidGlass {
            button.glassEffect(
                Glass.regular
                    .tint(foregroundStyle(for: control).opacity(0.18))
                    .interactive(isEnabled),
                in: Circle()
            )
        } else {
            button.background(
                Circle()
                    .fill(.primary.opacity(0.08))
            )
        }
    }

    func isControlEnabled(_ control: FloatingControl) -> Bool {
        control.isEnabled(
            isScreenshotCapturing:
                annotationViewModel.screenshotState == .capturing
        )
    }

    private func foregroundStyle(for control: FloatingControl) -> Color {
        switch control {
        case .record, .stop:
            .red
        case .pause:
            isPaused ? .green : .orange
        case .bookmark:
            .blue
        case .note:
            .indigo
        case .screenshot:
            annotationViewModel.screenshotState == .saved
                ? .green
                : .cyan
        }
    }
}
