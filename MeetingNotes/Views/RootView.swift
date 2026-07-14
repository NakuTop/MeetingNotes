import SwiftUI

struct RootView: View {
    private let ownedContainer: AppContainer?
    @Bindable var viewModel: MeetingLibraryViewModel
    let makeDetailViewModel: (UUID) -> MeetingDetailViewModel

    init(
        viewModel: MeetingLibraryViewModel,
        makeDetailViewModel: @escaping (UUID) -> MeetingDetailViewModel
    ) {
        ownedContainer = nil
        self.viewModel = viewModel
        self.makeDetailViewModel = makeDetailViewModel
    }

    init() {
        let container = AppContainer.inMemory()
        ownedContainer = container
        viewModel = container.libraryViewModel
        makeDetailViewModel = { meetingID in
            container.detailViewModel(for: meetingID)
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
                        viewModel: makeDetailViewModel(meeting.id)
                    )
                    .id(meeting.id)
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
