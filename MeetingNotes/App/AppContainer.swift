import Foundation

@MainActor
final class AppContainer {
    let repository: MeetingRepository
    let fileStore: MeetingFileStore
    let coordinator: MeetingCoordinator
    let panelController: FloatingPanelController
    let libraryViewModel: MeetingLibraryViewModel
    let settingsViewModel: SettingsViewModel

    private let controlRouter: MeetingControlRouter
    private let summarizeAndArchiveUseCase: SummarizeAndArchiveUseCase
    private var detailViewModels: [UUID: MeetingDetailViewModel] = [:]

    private init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore
    ) {
        self.repository = repository
        self.fileStore = fileStore

        let controlRouter = MeetingControlRouter()
        self.controlRouter = controlRouter

        let panelController = FloatingPanelController { [weak controlRouter] control in
            controlRouter?.handle(control)
        }
        self.panelController = panelController
        let panelPresenter = FloatingPanelPresenter(
            controller: panelController
        )
        let coordinator = MeetingCoordinator(
            dependencies: .live(
                repository: repository,
                fileStore: fileStore,
                panel: panelPresenter
            )
        )
        self.coordinator = coordinator
        let libraryViewModel = MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: fileStore,
            starter: coordinator
        )
        self.libraryViewModel = libraryViewModel
        let httpClient = URLSessionHTTPClient()
        let credentialStore = KeychainCredentialStore()
        let settingsStore = AppSettingsStore()
        let summarizeAndArchiveUseCase = SummarizeAndArchiveUseCase(
            repository: repository,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            summaryGenerator: LiveMeetingSummaryGenerator(
                httpClient: httpClient
            ),
            notionArchiver: LiveMeetingNotionArchiver(
                repository: repository,
                httpClient: httpClient
            )
        )
        self.summarizeAndArchiveUseCase = summarizeAndArchiveUseCase
        settingsViewModel = SettingsViewModel(
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            deepSeekTester: LiveDeepSeekConnectionTester(
                httpClient: httpClient
            ),
            notionTester: LiveNotionConnectionTester(
                httpClient: httpClient
            )
        )
        controlRouter.connect(
            coordinator: coordinator,
            panelController: panelController,
            libraryViewModel: libraryViewModel
        )
    }

    static func live() throws -> AppContainer {
        let repository = try MeetingRepository.persistent()
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let recordingsRoot = applicationSupport
            .appendingPathComponent("MeetingNotes", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        let fileStore = MeetingFileStore(rootURL: recordingsRoot)
        return AppContainer(
            repository: repository,
            fileStore: fileStore
        )
    }

    static func inMemory() -> AppContainer {
        guard let repository = try? MeetingRepository.inMemory() else {
            preconditionFailure("Unable to initialize the in-memory database")
        }
        let recordingsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeetingNotes-\(UUID().uuidString)",
                isDirectory: true
            )
        return AppContainer(
            repository: repository,
            fileStore: MeetingFileStore(rootURL: recordingsRoot)
        )
    }

    func detailViewModel(for meetingID: UUID) -> MeetingDetailViewModel {
        if let existing = detailViewModels[meetingID] {
            return existing
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: summarizeAndArchiveUseCase
        )
        detailViewModels[meetingID] = viewModel
        return viewModel
    }
}

@MainActor
private final class MeetingControlRouter {
    private var coordinator: MeetingCoordinator?
    private weak var panelController: FloatingPanelController?
    private weak var libraryViewModel: MeetingLibraryViewModel?

    func connect(
        coordinator: MeetingCoordinator,
        panelController: FloatingPanelController,
        libraryViewModel: MeetingLibraryViewModel
    ) {
        self.coordinator = coordinator
        self.panelController = panelController
        self.libraryViewModel = libraryViewModel
    }

    func handle(_ control: FloatingControl) {
        guard let coordinator else { return }

        Task { [weak self] in
            do {
                switch control {
                case .record:
                    return
                case .pause:
                    try await coordinator.pauseOrResume()
                    let snapshot = await coordinator.snapshot()
                    self?.panelController?.setPaused(
                        snapshot.state == .paused
                    )
                case .stop:
                    let meetingID = await coordinator.snapshot().meetingID
                    try await coordinator.stop()
                    self?.libraryViewModel?.load()
                    self?.libraryViewModel?.select(meetingID)
                case .bookmark:
                    try await coordinator.bookmark()
                    self?.libraryViewModel?.load()
                }
            } catch {
                self?.libraryViewModel?.reportControlFailure(error)
            }
        }
    }

}
