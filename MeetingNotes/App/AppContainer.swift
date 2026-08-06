import Foundation

@MainActor
final class AppContainer {
    private static var transcriptionModelStorage: TranscriptionModelStorage {
        let meetingNotesFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MeetingNotes", isDirectory: true)
        return TranscriptionModelStorage(
            modelsRoot: meetingNotesFolder.appendingPathComponent(
                "WhisperModels-v2",
                isDirectory: true
            ),
            legacyModelFolder: meetingNotesFolder.appendingPathComponent(
                "WhisperModels",
                isDirectory: true
            )
        )
    }
    private static var fluidAudioModelsFolder: URL {
        FileManager.default
            .urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )
            .first!
            .appendingPathComponent(
                "MeetingNotes/FluidAudioModels",
                isDirectory: true
            )
    }

    let repository: MeetingRepository
    let fileStore: MeetingFileStore
    let coordinator: MeetingCoordinator
    let panelController: FloatingPanelController
    let audioPlayerController: MeetingAudioPlayerController
    let audioOutputTester: any AudioOutputTesting
    let libraryViewModel: MeetingLibraryViewModel
    let settingsViewModel: SettingsViewModel
    let onboardingState: OnboardingState
    let transcriptionModelViewModel: TranscriptionModelViewModel
    let recordingPresentationStore: RecordingSessionPresentationStore

    private let controlRouter: MeetingControlRouter
    private let settingsStore: AppSettingsStore
    private let summarizeAndArchiveUseCase: SummarizeAndArchiveUseCase
    let meetingDocumentsUseCase: MeetingDocumentsUseCase
    private let meetingTitleUpdater: any MeetingTitleUpdating
    private let speakerDiarizationRetryer:
        any MeetingSpeakerDiarizationRetrying
    private let operationGate: MeetingOperationGate
    private var detailViewModels: [UUID: MeetingDetailViewModel] = [:]

    init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore,
        recordingsURL: URL,
        coordinatorDependencies: ((
            any RecordingPanelPresenting,
            any SpeakerDiarizationPreferenceReading,
            RecordingSessionPresentationStore
        ) -> MeetingCoordinatorDependencies)? = nil,
        modelPreparer: (any TranscriptionModelPreparing)? = nil,
        credentialStore: (any CredentialStore)? = nil,
        settingsStore: AppSettingsStore? = nil,
        deepSeekTester: (any DeepSeekConnectionTesting)? = nil,
        notionTester: (any NotionConnectionTesting)? = nil,
        summaryGenerator: (any MeetingSummaryGenerating)? = nil,
        detailedMinutesGenerator:
            (any MeetingDetailedMinutesGenerating)? = nil,
        notionArchiver: (any MeetingNotionArchiving)? = nil,
        documentArchiver: (any MeetingDocumentArchiving)? = nil,
        notionTitleUpdater: (any MeetingNotionTitleUpdating)? = nil,
        onboardingState: OnboardingState? = nil,
        systemRequirements: (any SystemRequirementChecking)? = nil,
        audioDeviceCatalog: (any AudioDeviceDiscovering)? = nil,
        audioInputTester: (any AudioDiagnosticSignalTesting)? = nil,
        audioOutputTester: (any AudioOutputTesting)? = nil,
        audioDiagnosticCoordinatorFactory:
            (any AudioDiagnosticCoordinatorCreating)? = nil,
        audioDiagnosticExplainer:
            (any AudioDiagnosticExplanationRequesting)? = nil
    ) {
        self.repository = repository
        self.fileStore = fileStore
        let settingsStore = settingsStore ?? AppSettingsStore()
        self.settingsStore = settingsStore
        let audioDeviceCatalog = audioDeviceCatalog ?? AudioDeviceCatalog()
        let permissionSystem = LiveCapturePermissionSystem()
        let speakerDiarizationPreference =
            MainActorSpeakerDiarizationPreferenceAdapter(
                settingsStore: settingsStore
            )
        let transcriptionQualityPreference =
            MainActorTranscriptionQualityPreferenceAdapter(
                settingsStore: settingsStore
            )
        let audioInputDevicePreference =
            MainActorAudioInputDevicePreferenceAdapter(
                settingsStore: settingsStore,
                deviceCatalog: audioDeviceCatalog
            )
        let audioOutputDevicePreference =
            MainActorAudioOutputDevicePreferenceAdapter(
                settingsStore: settingsStore,
                deviceCatalog: audioDeviceCatalog
            )
        let audioOutputTester = audioOutputTester ?? LiveAudioOutputTester(
            preference: audioOutputDevicePreference
        )
        self.audioOutputTester = audioOutputTester

        let controlRouter = MeetingControlRouter()
        self.controlRouter = controlRouter
        let recordingPresentationStore =
            RecordingSessionPresentationStore()
        self.recordingPresentationStore = recordingPresentationStore

        let panelController = FloatingPanelController(
            recordingPresentationStore: recordingPresentationStore
        ) { [weak controlRouter] control in
            controlRouter?.handle(control)
        }
        self.panelController = panelController
        let panelPresenter = FloatingPanelPresenter(
            controller: panelController
        )
        let transcriptionModelController = TranscriptionModelController(
            storage: Self.transcriptionModelStorage
        )
        let sourceLoader = MeetingAudioSourceLoader(fileStore: fileStore)
        let speakerDiarizer = FluidAudioSpeakerDiarizer(
            modelsDirectory: Self.fluidAudioModelsFolder,
            sourceLoader: sourceLoader
        )
        if let modelPreparer {
            transcriptionModelViewModel = TranscriptionModelViewModel(
                preparer: modelPreparer,
                selectedMode: settingsStore.transcriptionQualityMode
            )
        } else {
            transcriptionModelViewModel = TranscriptionModelViewModel(
                controller: transcriptionModelController,
                selectedMode: settingsStore.transcriptionQualityMode
            )
        }
        self.onboardingState = onboardingState ?? OnboardingState()
        let dependencies = coordinatorDependencies?(
            panelPresenter,
            speakerDiarizationPreference,
            recordingPresentationStore
        ) ?? .live(
            repository: repository,
            fileStore: fileStore,
            speakerDiarizationPreference: speakerDiarizationPreference,
            audioInputDevicePreference: audioInputDevicePreference,
            permissionSystem: permissionSystem,
            panel: panelPresenter,
            recordingPresentation: recordingPresentationStore,
            captureInterruptionReporter: controlRouter,
            sourceLoader: sourceLoader,
            transcriptionModelController: transcriptionModelController,
            transcriptionQualityPreference:
                transcriptionQualityPreference,
            speakerDiarizer: speakerDiarizer
        )
        let coordinator = MeetingCoordinator(
            dependencies: dependencies
        )
        self.coordinator = coordinator
        let httpClient = URLSessionHTTPClient()
        let credentialStore = credentialStore ?? KeychainCredentialStore()
        let operationGate = MeetingOperationGate()
        self.operationGate = operationGate
        let onlineTranscriptRebuilder = OnlineMeetingTranscriptRebuilder(
            reader: MeetingTrackAudioReader(sourceLoader: sourceLoader),
            sourceLoader: sourceLoader,
            diarizer: speakerDiarizer
        )
        let speakerDiarizationRetryer = SpeakerDiarizationRetryUseCase(
            repository: repository,
            sourceLoader: sourceLoader,
            diarizer: speakerDiarizer,
            operationGate: operationGate,
            onlineRebuilder: onlineTranscriptRebuilder,
            transcriptionServiceProvider:
                PreferredTranscriptionServiceProvider(
                    controller: transcriptionModelController,
                    preference: transcriptionQualityPreference
                )
        )
        self.speakerDiarizationRetryer = speakerDiarizationRetryer
        let titleUpdater = MeetingTitleUpdateUseCase(
            repository: repository,
            credentialStore: credentialStore,
            notionTitleUpdater: notionTitleUpdater
                ?? LiveMeetingNotionTitleUpdater(httpClient: httpClient),
            operationGate: operationGate
        )
        self.meetingTitleUpdater = titleUpdater
        let audioPlayerController = MeetingAudioPlayerController(
            sourceLoader: sourceLoader,
            waveformLoader: WaveformAnalyzer(fileStore: fileStore),
            engine: AVFoundationMeetingAudioPlaybackEngine(
                outputDevicePreference: audioOutputDevicePreference
            )
        )
        self.audioPlayerController = audioPlayerController
        let recoveryService = MeetingRecoveryService(
            repository: repository,
            fileStore: fileStore
        )
        let libraryViewModel = MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: fileStore,
            starter: coordinator,
            titleUpdater: titleUpdater,
            operationGate: operationGate,
            playbackStopper: audioPlayerController,
            deletionPreparer: coordinator,
            recovery: recoveryService,
            systemRequirements: systemRequirements ?? SystemRequirements(),
            recordingsURL: recordingsURL
        )
        self.libraryViewModel = libraryViewModel
        let summaryGenerator = summaryGenerator
            ?? LiveMeetingSummaryGenerator(httpClient: httpClient)
        let notionArchiver = notionArchiver
            ?? LiveMeetingNotionArchiver(
                repository: repository,
                httpClient: httpClient
            )
        let meetingDocumentsUseCase = MeetingDocumentsUseCase(
            repository: repository,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            summaryGenerator: summaryGenerator,
            detailedMinutesGenerator: detailedMinutesGenerator
                ?? LiveMeetingDetailedMinutesGenerator(httpClient: httpClient),
            archiver: documentArchiver
                ?? LegacyMeetingDocumentNotionArchiver(
                    repository: repository,
                    archiver: notionArchiver
                ),
            operationGate: operationGate
        )
        self.meetingDocumentsUseCase = meetingDocumentsUseCase
        let summarizeAndArchiveUseCase = SummarizeAndArchiveUseCase(
            repository: repository,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            summaryGenerator: summaryGenerator,
            notionArchiver: notionArchiver,
            operationGate: operationGate,
            documentsUseCase: meetingDocumentsUseCase
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
            ),
            audioDeviceCatalog: audioDeviceCatalog,
            recordingActivity:
                MeetingCoordinatorAudioDiagnosticRecordingChecker(
                    coordinator: coordinator
                ),
            audioInputTester: audioInputTester
                ?? LiveMicrophoneAudioDiagnosticSignalTester(
                    provider: AVCaptureMicrophoneSampleProvider(),
                    inputPreference: audioInputDevicePreference
                ),
            audioOutputTester: audioOutputTester,
            diagnosticCoordinatorFactory: audioDiagnosticCoordinatorFactory
                ?? LiveAudioDiagnosticCoordinatorFactory(
                    recordingActivity:
                        MeetingCoordinatorAudioDiagnosticRecordingChecker(
                            coordinator: coordinator
                        ),
                    permissions: LiveAudioDiagnosticPermissionChecker(
                        system: permissionSystem
                    ),
                    inputDevice: LiveAudioDiagnosticInputDeviceChecker(
                        catalog: audioDeviceCatalog,
                        preference: audioInputDevicePreference
                    ),
                    outputTester: audioOutputTester,
                    inputPreference: audioInputDevicePreference
                ),
            diagnosticExplainer: audioDiagnosticExplainer
                ?? LiveAudioDiagnosticExplanationRequester(
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
            recordingsURL: recordingsRoot,
            credentialStore: EphemeralCredentialStore(
                deepSeekAPIKey: "preview-deepseek-key",
                notionToken: "preview-notion-token"
            ),
            notionTitleUpdater: NoopMeetingNotionTitleUpdater()
        )
    }

    func detailViewModel(for meetingID: UUID) -> MeetingDetailViewModel {
        if let existing = detailViewModels[meetingID] {
            return existing
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: settingsStore,
            action: summarizeAndArchiveUseCase,
            documentManager: meetingDocumentsUseCase,
            titleUpdater: meetingTitleUpdater,
            speakerDiarizationRetryer: speakerDiarizationRetryer,
            recordingPresentationStore: recordingPresentationStore
        )
        detailViewModels[meetingID] = viewModel
        return viewModel
    }
}

@MainActor
private final class MeetingControlRouter:
    MeetingCaptureInterruptionReporting {
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

    func captureInterrupted(meetingID: UUID) async {
        libraryViewModel?.load()
        libraryViewModel?.select(meetingID)
        libraryViewModel?.reportCaptureInterruption()
    }
}
