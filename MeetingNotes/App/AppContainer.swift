import Foundation

@MainActor
final class AppContainer {
    let repository: MeetingRepository
    let fileStore: MeetingFileStore
    let coordinator: MeetingCoordinator
    let panelController: FloatingPanelController
    let libraryViewModel: MeetingLibraryViewModel
    let settingsViewModel: SettingsViewModel
    let onboardingState: OnboardingState
    let transcriptionModelViewModel: TranscriptionModelViewModel

    private let controlRouter: MeetingControlRouter
    private let summarizeAndArchiveUseCase: SummarizeAndArchiveUseCase
    private let meetingTitleUpdater: any MeetingTitleUpdating
    private var detailViewModels: [UUID: MeetingDetailViewModel] = [:]

    init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore,
        recordingsURL: URL,
        coordinatorDependencies: ((any RecordingPanelPresenting) ->
            MeetingCoordinatorDependencies)? = nil,
        modelPreparer: (any TranscriptionModelPreparing)? = nil,
        credentialStore: (any CredentialStore)? = nil,
        settingsStore: AppSettingsStore? = nil,
        deepSeekTester: (any DeepSeekConnectionTesting)? = nil,
        notionTester: (any NotionConnectionTesting)? = nil,
        summaryGenerator: (any MeetingSummaryGenerating)? = nil,
        notionArchiver: (any MeetingNotionArchiving)? = nil,
        meetingTitleUpdater: (any MeetingTitleUpdating)? = nil,
        onboardingState: OnboardingState? = nil,
        systemRequirements: (any SystemRequirementChecking)? = nil
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
        let transcriptionService = WhisperKitTranscriptionService()
        transcriptionModelViewModel = TranscriptionModelViewModel(
            preparer: modelPreparer ?? transcriptionService
        )
        self.onboardingState = onboardingState ?? OnboardingState()
        let dependencies = coordinatorDependencies?(panelPresenter) ?? .live(
            repository: repository,
            fileStore: fileStore,
            panel: panelPresenter,
            transcriptionService: transcriptionService
        )
        let coordinator = MeetingCoordinator(
            dependencies: dependencies
        )
        self.coordinator = coordinator
        let httpClient = URLSessionHTTPClient()
        let credentialStore = credentialStore ?? KeychainCredentialStore()
        let titleUpdater = meetingTitleUpdater ?? MeetingTitleUpdateUseCase(
            repository: repository,
            credentialStore: credentialStore,
            notionTitleUpdater: LiveMeetingNotionTitleUpdater(
                httpClient: httpClient
            )
        )
        self.meetingTitleUpdater = titleUpdater
        let libraryViewModel = MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: fileStore,
            starter: coordinator,
            titleUpdater: titleUpdater,
            systemRequirements: systemRequirements ?? SystemRequirements(),
            recordingsURL: recordingsURL
        )
        self.libraryViewModel = libraryViewModel
        let settingsStore = settingsStore ?? AppSettingsStore()
        let summarizeAndArchiveUseCase = SummarizeAndArchiveUseCase(
            repository: repository,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            summaryGenerator: summaryGenerator ?? LiveMeetingSummaryGenerator(
                httpClient: httpClient
            ),
            notionArchiver: notionArchiver ?? LiveMeetingNotionArchiver(
                repository: repository,
                httpClient: httpClient
            )
        )
        self.summarizeAndArchiveUseCase = summarizeAndArchiveUseCase
        settingsViewModel = SettingsViewModel(
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            deepSeekTester: deepSeekTester ?? LiveDeepSeekConnectionTester(
                httpClient: httpClient
            ),
            notionTester: notionTester ?? LiveNotionConnectionTester(
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
            fileStore: fileStore,
            recordingsURL: recordingsRoot
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
            fileStore: MeetingFileStore(rootURL: recordingsRoot),
            recordingsURL: recordingsRoot
        )
    }

    func detailViewModel(for meetingID: UUID) -> MeetingDetailViewModel {
        if let existing = detailViewModels[meetingID] {
            return existing
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            action: summarizeAndArchiveUseCase,
            titleUpdater: meetingTitleUpdater
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
