import SwiftUI

struct RootView: View {
    private let ownedContainer: AppContainer?
    @Bindable var viewModel: MeetingLibraryViewModel
    let requestSummary: (UUID) -> Void

    init(
        viewModel: MeetingLibraryViewModel,
        requestSummary: @escaping (UUID) -> Void
    ) {
        ownedContainer = nil
        self.viewModel = viewModel
        self.requestSummary = requestSummary
    }

    init() {
        let container = AppContainer.inMemory()
        ownedContainer = container
        viewModel = container.libraryViewModel
        requestSummary = { meetingID in
            container.requestSummary(for: meetingID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                MeetingSidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            } detail: {
                if let meeting = viewModel.selectedMeeting {
                    MeetingDetailView(
                        meeting: meeting,
                        canSummarize: viewModel.canSummarize(
                            meetingIn: meeting.state
                        ),
                        requestSummary: {
                            requestSummary(meeting.id)
                        }
                    )
                } else {
                    StartMeetingView(viewModel: viewModel)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("关闭") {
                        viewModel.dismissError()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.bar)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            viewModel.load()
        }
    }
}
