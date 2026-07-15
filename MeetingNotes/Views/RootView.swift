import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let ownedContainer: AppContainer?
    @Bindable var viewModel: MeetingLibraryViewModel
    @Bindable var onboardingState: OnboardingState
    @Bindable var transcriptionModelViewModel: TranscriptionModelViewModel
    let makeDetailViewModel: (UUID) -> MeetingDetailViewModel

    init(
        viewModel: MeetingLibraryViewModel,
        onboardingState: OnboardingState,
        transcriptionModelViewModel: TranscriptionModelViewModel,
        makeDetailViewModel: @escaping (UUID) -> MeetingDetailViewModel
    ) {
        ownedContainer = nil
        self.viewModel = viewModel
        self.onboardingState = onboardingState
        self.transcriptionModelViewModel = transcriptionModelViewModel
        self.makeDetailViewModel = makeDetailViewModel
    }

    init() {
        let container = AppContainer.inMemory()
        ownedContainer = container
        viewModel = container.libraryViewModel
        onboardingState = container.onboardingState
        transcriptionModelViewModel = container.transcriptionModelViewModel
        makeDetailViewModel = { meetingID in
            container.detailViewModel(for: meetingID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.systemRequirementsSnapshot.isSupportedPlatform {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    MeetingSidebarView(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                } detail: {
                    Group {
                        if let meeting = viewModel.selectedMeeting {
                            MeetingDetailView(
                                viewModel: makeDetailViewModel(meeting.id),
                                onReturnHome: {
                                    viewModel.returnHome()
                                },
                                onMeetingChanged: {
                                    viewModel.load()
                                }
                            )
                            .id(meeting.id)
                            .transition(detailTransition)
                        } else {
                            VStack(spacing: 0) {
                                StartMeetingView(viewModel: viewModel)
                                ModelStatusView(
                                    viewModel: transcriptionModelViewModel
                                )
                                .padding(.horizontal, 28)
                                .padding(.bottom, 22)
                            }
                            .transition(detailTransition)
                        }
                    }
                    .animation(
                        AppVisualPolicy.motion(reduceMotion: reduceMotion)
                            .animation,
                        value: viewModel.selectedMeetingID
                    )
                }
            } else {
                ContentUnavailableView(
                    "此 Mac 不受支持",
                    systemImage: "macbook.and.iphone",
                    description: Text(
                        "会议记录需要 macOS 15 或更高版本的 Apple Silicon Mac。"
                    )
                )
            }

            if let errorMessage = viewModel.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(
                        viewModel.permissionRepairPermissions,
                        id: \.self
                    ) { permission in
                        if let url = SystemRequirements.settingsURL(
                            for: permission
                        ) {
                            Link(destination: url) {
                                Label(
                                    repairTitle(for: permission),
                                    systemImage: "gear"
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                    Button("关闭") {
                        viewModel.dismissError()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .adaptiveGlassSurface(
                    in: RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    ),
                    tint: .orange.opacity(0.08)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.windowGlassSurface")
        .containerBackground(for: .window) {
            AppWindowGlassBackground()
        }
        .task {
            viewModel.load()
        }
        .sheet(
            isPresented: Binding(
                get: {
                    onboardingState.shouldPresentPrivacyAndConsent
                },
                set: { _ in }
            )
        ) {
            OnboardingView(state: onboardingState)
        }
    }

    private func repairTitle(for permission: CapturePermission) -> String {
        switch permission {
        case .microphone: "打开麦克风设置"
        case .screenRecording: "打开屏幕录制设置"
        }
    }

    private var detailTransition: AnyTransition {
        let motion = AppVisualPolicy.motion(reduceMotion: reduceMotion)
        return .opacity.combined(with: .scale(scale: motion.scale))
    }
}
