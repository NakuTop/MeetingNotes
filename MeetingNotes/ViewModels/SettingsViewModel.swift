import Foundation
import Observation

enum CredentialPresence: Equatable, Sendable {
    case missing
    case saved(maskedValue: String)
}

enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case succeeded(message: String)
    case failed(message: String)

    var isTesting: Bool {
        self == .testing
    }
}

enum AudioDiagnosticPhase: Equatable, Sendable {
    case checkingPermissions
    case playingOutputTone
    case testingMicrophone
    case testingSystemAudio
}

struct AudioDiagnosticPreview: Equatable, Sendable {
    let primaryIssue: AudioDiagnosticIssueCode
    let supportingIssues: [AudioDiagnosticIssueCode]
    let localIssue: String
    let localSolution: String
    let allowlistedJSON: String
}

struct AudioDiagnosticPresentation: Equatable, Sendable {
    let local: AudioDiagnosticPreview
    let issue: String
    let solution: String
    let source: AudioDiagnosticExplanationSource
}

enum AudioDiagnosticViewState: Equatable, Sendable {
    case idle
    case running(AudioDiagnosticPhase)
    case awaitingOutputConfirmation
    case readyForUpload(AudioDiagnosticPreview)
    case explaining(AudioDiagnosticPreview)
    case completed(AudioDiagnosticPresentation)
    case failed(local: AudioDiagnosticPreview?, message: String)
}

enum AudioInputTestState: Equatable, Sendable {
    case idle
    case testing(AudioSignalMetrics?)
    case completed(AudioSignalMetrics)
    case failed(message: String)
}

enum AudioOutputTestState: Equatable, Sendable {
    case idle
    case testing
    case succeeded(message: String)
    case failed(message: String)
}

struct AudioDiagnosticEnvironmentInfo: Equatable, Sendable {
    let appVersion: String
    let hardwareModel: String
    let macOSVersion: String
}

protocol AudioDiagnosticEnvironmentInfoProviding: Sendable {
    func environmentInfo() -> AudioDiagnosticEnvironmentInfo
}

struct LiveAudioDiagnosticEnvironmentInfoProvider:
    AudioDiagnosticEnvironmentInfoProviding {
    func environmentInfo() -> AudioDiagnosticEnvironmentInfo {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = [
            systemVersion.majorVersion,
            systemVersion.minorVersion,
            systemVersion.patchVersion
        ].map(String.init).joined(separator: ".")
        #if arch(arm64)
        let hardwareModel = "Apple Silicon"
        #else
        let hardwareModel = "Unsupported Mac"
        #endif
        return AudioDiagnosticEnvironmentInfo(
            appVersion: version,
            hardwareModel: hardwareModel,
            macOSVersion: macOSVersion
        )
    }
}

protocol AudioDiagnosticExplanationRequesting: Sendable {
    func requestExplanation(
        apiKey: String,
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata,
        model: String
    ) async throws -> AudioDiagnosticExplanation
}

struct LiveAudioDiagnosticExplanationRequester:
    AudioDiagnosticExplanationRequesting {
    let httpClient: any HTTPClient

    func requestExplanation(
        apiKey: String,
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata,
        model: String
    ) async throws -> AudioDiagnosticExplanation {
        try await DeepSeekAudioDiagnosticClient(
            apiKey: apiKey,
            httpClient: httpClient
        ).requestExplanation(
            report: report,
            metadata: metadata,
            model: model
        )
    }
}

private struct InactiveAudioDiagnosticRecordingActivity:
    AudioDiagnosticRecordingActivityChecking {
    func isRecordingActive() async -> Bool {
        false
    }
}

private enum SettingsAudioOperation: Equatable {
    case inputTest
    case outputTest
    case diagnostic
}

protocol DeepSeekConnectionTesting: Sendable {
    func testConnection(apiKey: String) async throws -> [String]
}

struct LiveDeepSeekConnectionTester: DeepSeekConnectionTesting {
    let httpClient: any HTTPClient

    func testConnection(apiKey: String) async throws -> [String] {
        try await DeepSeekClient(
            apiKey: apiKey,
            httpClient: httpClient
        ).testConnection()
    }
}

protocol NotionConnectionTesting: Sendable {
    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult
}

struct LiveNotionConnectionTester: NotionConnectionTesting {
    let httpClient: any HTTPClient

    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        try await NotionClient(
            token: token,
            httpClient: httpClient
        ).testConnection(parentPageID: parentPageID)
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    private let credentialStore: any CredentialStore
    private let settingsStore: AppSettingsStore
    private let deepSeekTester: any DeepSeekConnectionTesting
    private let notionTester: any NotionConnectionTesting
    private let audioDeviceCatalog: any AudioDeviceDiscovering
    private let audioDeviceChangeObserver: any AudioDeviceChangeObserving
    private let recordingActivity:
        any AudioDiagnosticRecordingActivityChecking
    private let audioInputTester: (any AudioDiagnosticSignalTesting)?
    private let audioOutputTester: (any AudioOutputTesting)?
    private let diagnosticCoordinatorFactory:
        (any AudioDiagnosticCoordinatorCreating)?
    private let diagnosticExplainer:
        (any AudioDiagnosticExplanationRequesting)?
    private let diagnosticEnvironment:
        any AudioDiagnosticEnvironmentInfoProviding
    private let diagnosticSanitizer = AudioDiagnosticSanitizer()
    private let microphoneRuntime: (any MicrophoneRuntimeReporting)?

    var deepSeekAPIKeyInput = ""
    var notionTokenInput = ""
    var selectedModel = AppSettingsStore.defaultDeepSeekModel
    var notionParentPageURL = ""
    var isNotionArchivingEnabled = true
    var isSpeakerDiarizationEnabled = false
    var frequentSpeakerNames: [String] = []
    var newSpeakerName = ""
    var selectedTranscriptionQualityMode: TranscriptionQualityMode = .balanced
    var selectedInputDeviceID: String?
    var selectedOutputDeviceID: String?

    private(set) var availableModels = [
        AppSettingsStore.defaultDeepSeekModel
    ]
    private(set) var deepSeekCredential: CredentialPresence = .missing
    private(set) var notionCredential: CredentialPresence = .missing
    private(set) var deepSeekConnection: ConnectionTestState = .idle
    private(set) var notionConnection: ConnectionTestState = .idle
    private(set) var saveState: ConnectionTestState = .idle
    private(set) var audioDevices = AudioDeviceSnapshot(
        inputs: [],
        outputs: []
    )
    private(set) var resolvedInputDevice:
        ResolvedAudioDevice<AudioInputDevice> = .unavailable
    private(set) var resolvedInputCapture: ResolvedMicrophoneCapture?
    private(set) var resolvedOutputDevice:
        ResolvedAudioDevice<AudioOutputDevice> = .unavailable
    private(set) var microphoneRuntimeSnapshot =
        MicrophoneRuntimeSnapshot()
    private(set) var audioDeviceMessage: String?
    private(set) var isRefreshingAudioDevices = false
    private(set) var areAudioControlsDisabled = false
    private(set) var audioInputTestState: AudioInputTestState = .idle
    private(set) var audioOutputTestState: AudioOutputTestState = .idle
    private(set) var audioDiagnosticState: AudioDiagnosticViewState = .idle

    var areTranscriptionControlsDisabled: Bool {
        areAudioControlsDisabled
    }

    var isCoreAudioFallbackActive: Bool {
        let runtime = microphoneRuntimeSnapshot
        guard runtime.telemetry.captureStarted,
              runtime.telemetry.captureBackend
                == .coreAudioFallback else {
            return false
        }
        switch runtime.status {
        case .stopped, .failed:
            return false
        default:
            return true
        }
    }

    var isMicrophoneRecovering: Bool {
        microphoneRuntimeSnapshot.status == .recovering
    }

    var avFoundationInputCount: Int {
        audioDevices.inputs.filter(\.isAVFoundationAvailable).count
    }

    var coreAudioInputCount: Int {
        audioDevices.inputs.filter(\.isCoreAudioAvailable).count
    }

    private var activeDiagnostic: (any AudioDiagnosticCoordinating)?
    private var latestDiagnosticReport: AudioDiagnosticReport?
    private var latestDiagnosticMetadata: AudioDiagnosticUploadMetadata?
    private var diagnosticGeneration: UInt64 = 0
    private var inputTestGeneration: UInt64 = 0
    private var outputTestGeneration: UInt64 = 0
    private var activeAudioOperation: SettingsAudioOperation?
    private var isCancellingAudioOperation = false
    private var audioSettingsSessionGeneration: UInt64 = 0
    private var isAudioSettingsVisible = true
    private var isAudioDeviceRefreshPending = false

    init(
        credentialStore: any CredentialStore,
        settingsStore: AppSettingsStore,
        deepSeekTester: any DeepSeekConnectionTesting,
        notionTester: any NotionConnectionTesting,
        audioDeviceCatalog: any AudioDeviceDiscovering = AudioDeviceCatalog(),
        audioDeviceChangeObserver: any AudioDeviceChangeObserving =
            CoreAudioDeviceChangeObserver(),
        recordingActivity:
            any AudioDiagnosticRecordingActivityChecking =
                InactiveAudioDiagnosticRecordingActivity(),
        audioInputTester: (any AudioDiagnosticSignalTesting)? = nil,
        audioOutputTester: (any AudioOutputTesting)? = nil,
        diagnosticCoordinatorFactory:
            (any AudioDiagnosticCoordinatorCreating)? = nil,
        diagnosticExplainer:
            (any AudioDiagnosticExplanationRequesting)? = nil,
        diagnosticEnvironment:
            any AudioDiagnosticEnvironmentInfoProviding =
                LiveAudioDiagnosticEnvironmentInfoProvider(),
        microphoneRuntime: (any MicrophoneRuntimeReporting)? = nil
    ) {
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.deepSeekTester = deepSeekTester
        self.notionTester = notionTester
        self.audioDeviceCatalog = audioDeviceCatalog
        self.audioDeviceChangeObserver = audioDeviceChangeObserver
        self.recordingActivity = recordingActivity
        self.audioInputTester = audioInputTester
        self.audioOutputTester = audioOutputTester
        self.diagnosticCoordinatorFactory = diagnosticCoordinatorFactory
        self.diagnosticExplainer = diagnosticExplainer
        self.diagnosticEnvironment = diagnosticEnvironment
        self.microphoneRuntime = microphoneRuntime
    }

    func load() {
        deepSeekAPIKeyInput = ""
        notionTokenInput = ""
        deepSeekConnection = .idle
        notionConnection = .idle
        selectedModel = settingsStore.deepSeekModel
        notionParentPageURL = settingsStore.notionParentPageURL
        isNotionArchivingEnabled = settingsStore.isNotionArchivingEnabled
        isSpeakerDiarizationEnabled =
            settingsStore.isSpeakerDiarizationEnabled
        frequentSpeakerNames = settingsStore.frequentSpeakerNames
        newSpeakerName = ""
        selectedTranscriptionQualityMode =
            settingsStore.transcriptionQualityMode
        selectedInputDeviceID = settingsStore.preferredInputDeviceID
        selectedOutputDeviceID = settingsStore.preferredOutputDeviceID
        if !availableModels.contains(selectedModel) {
            availableModels.append(selectedModel)
        }
        availableModels = Array(Set(availableModels)).sorted()

        do {
            try refreshCredentialPresence()
            saveState = .idle
        } catch {
            saveState = .failed(
                message: "无法读取钥匙串，请解锁登录钥匙串后重试。"
            )
        }
    }

    @discardableResult
    func save() async -> Bool {
        let isRecordingActive = await recordingActivity.isRecordingActive()
        areAudioControlsDisabled = isRecordingActive
        guard !isRecordingActive else {
            saveState = .failed(
                message: "会议录音进行中，无法保存设置。"
            )
            return false
        }

        let deepSeekInput = deepSeekAPIKeyInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let notionInput = notionTokenInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        do {
            if !deepSeekInput.isEmpty {
                try credentialStore.save(
                    deepSeekInput,
                    for: .deepSeekAPIKey
                )
            }
            if !notionInput.isEmpty {
                try credentialStore.save(
                    notionInput,
                    for: .notionToken
                )
            }
            settingsStore.deepSeekModel = selectedModel
            settingsStore.notionParentPageURL = notionParentPageURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            settingsStore.isNotionArchivingEnabled = isNotionArchivingEnabled
            settingsStore.isSpeakerDiarizationEnabled =
                isSpeakerDiarizationEnabled
            settingsStore.transcriptionQualityMode =
                selectedTranscriptionQualityMode
            settingsStore.preferredInputDeviceID = selectedInputDeviceID
            settingsStore.preferredOutputDeviceID = selectedOutputDeviceID
            settingsStore.preferredAudioInput = Self.preferredAudioInput(
                selectedID: selectedInputDeviceID,
                inputs: audioDevices.inputs
            )
            notionParentPageURL = settingsStore.notionParentPageURL
            selectedModel = settingsStore.deepSeekModel
            frequentSpeakerNames = settingsStore.frequentSpeakerNames
            deepSeekAPIKeyInput = ""
            notionTokenInput = ""
            try refreshCredentialPresence()
            saveState = .succeeded(message: "设置已安全保存")
            return true
        } catch {
            saveState = .failed(
                message: "保存失败，请确认钥匙串可用后重试。"
            )
            return false
        }
    }

    func addFrequentSpeakerName() {
        settingsStore.frequentSpeakerNames =
            settingsStore.frequentSpeakerNames + [newSpeakerName]
        frequentSpeakerNames = settingsStore.frequentSpeakerNames
        newSpeakerName = ""
    }

    func removeFrequentSpeakerName(_ name: String) {
        var latestNames = settingsStore.frequentSpeakerNames
        latestNames.removeAll {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        settingsStore.frequentSpeakerNames = latestNames
        frequentSpeakerNames = settingsStore.frequentSpeakerNames
    }

    func refreshAudioDevices() async {
        guard !isRefreshingAudioDevices else {
            isAudioDeviceRefreshPending = true
            return
        }

        isRefreshingAudioDevices = true
        defer {
            isRefreshingAudioDevices = false
        }

        repeat {
            isAudioDeviceRefreshPending = false
            let settingsSession = audioSettingsSessionGeneration
            do {
                let snapshot = try await audioDeviceCatalog.snapshot()
                guard isAudioSettingsVisible,
                      audioSettingsSessionGeneration == settingsSession else {
                    continue
                }
                let inputResolution = AudioInputDeviceResolver
                    .resolveCapture(
                        preferred: settingsStore.preferredAudioInput,
                        inputs: snapshot.inputs
                    )
                let outputResolution =
                    AudioDevicePreferenceResolver.resolveOutput(
                        preferredID: selectedOutputDeviceID,
                        devices: snapshot.outputs
                    )

                audioDevices = snapshot
                resolvedInputCapture = inputResolution
                resolvedInputDevice = Self.resolvedInputDevice(
                    from: inputResolution
                )
                resolvedOutputDevice = outputResolution
                if let microphoneRuntime {
                    microphoneRuntimeSnapshot =
                        await microphoneRuntime.runtimeSnapshot()
                }
                audioDeviceMessage = Self.audioDeviceMessage(
                    input: resolvedInputDevice,
                    output: resolvedOutputDevice,
                    usesCoreAudioFallback: isCoreAudioFallbackActive,
                    isRecovering:
                        microphoneRuntimeSnapshot.status == .recovering
                )
            } catch {
                guard isAudioSettingsVisible,
                      audioSettingsSessionGeneration == settingsSession else {
                    continue
                }
                audioDeviceMessage = "无法读取音频设备，请稍后重试。"
            }
        } while isAudioSettingsVisible && isAudioDeviceRefreshPending
    }

    func refreshAudioControlAvailability() async {
        let isRecordingActive = await recordingActivity.isRecordingActive()
        areAudioControlsDisabled = isRecordingActive
        if isRecordingActive, activeAudioOperation != nil {
            await cancelAudioDiagnostic()
        }
    }

    func testSelectedInput() async {
        let settingsSession = audioSettingsSessionGeneration
        if case .testing = audioInputTestState { return }
        await refreshAudioControlAvailability()
        guard !areAudioControlsDisabled else {
            audioInputTestState = .failed(
                message: "录音进行中无法测试麦克风。"
            )
            return
        }
        guard let audioInputTester else {
            audioInputTestState = .failed(
                message: "麦克风测试当前不可用。"
            )
            return
        }
        guard claimAudioOperation(
            .inputTest,
            settingsSession: settingsSession
        ) else { return }

        applySelectedAudioDevicesForTesting()
        inputTestGeneration &+= 1
        let requestedGeneration = inputTestGeneration
        defer {
            releaseAudioOperation(.inputTest)
        }
        audioInputTestState = .testing(nil)
        do {
            let metrics = try await audioInputTester.testSignal(
                duration: 3
            ) { [weak self] metrics in
                await self?.receiveInputMetrics(
                    metrics,
                    generation: requestedGeneration
                )
            }
            guard inputTestGeneration == requestedGeneration else { return }
            audioInputTestState = .completed(metrics)
            await refreshMicrophoneRuntimeIfCurrent(requestedGeneration)
        } catch is CancellationError {
            guard inputTestGeneration == requestedGeneration else { return }
            audioInputTestState = .idle
            await refreshMicrophoneRuntimeIfCurrent(requestedGeneration)
        } catch {
            guard inputTestGeneration == requestedGeneration else { return }
            audioInputTestState = .failed(
                message: "麦克风测试失败，请检查设备连接与权限。"
            )
            await refreshMicrophoneRuntimeIfCurrent(requestedGeneration)
        }
    }

    func testSelectedOutput() async {
        let settingsSession = audioSettingsSessionGeneration
        guard audioOutputTestState != .testing else { return }
        await refreshAudioControlAvailability()
        guard !areAudioControlsDisabled else {
            audioOutputTestState = .failed(
                message: "录音进行中无法播放测试音。"
            )
            return
        }
        guard let audioOutputTester else {
            audioOutputTestState = .failed(
                message: "输出测试当前不可用。"
            )
            return
        }
        guard claimAudioOperation(
            .outputTest,
            settingsSession: settingsSession
        ) else { return }

        applySelectedAudioDevicesForTesting()
        outputTestGeneration &+= 1
        let requestedGeneration = outputTestGeneration
        defer {
            releaseAudioOperation(.outputTest)
        }
        audioOutputTestState = .testing
        do {
            _ = try await audioOutputTester.playTestTone(duration: 1)
            guard outputTestGeneration == requestedGeneration else { return }
            audioOutputTestState = .succeeded(message: "测试音已播放")
        } catch is CancellationError {
            guard outputTestGeneration == requestedGeneration else { return }
            audioOutputTestState = .idle
        } catch {
            guard outputTestGeneration == requestedGeneration else { return }
            audioOutputTestState = .failed(
                message: "输出测试失败，请检查设备连接与音量。"
            )
        }
    }

    func startSmartDiagnostic() async {
        let settingsSession = audioSettingsSessionGeneration
        guard audioDiagnosticState == .idle else { return }
        await refreshAudioControlAvailability()
        guard !areAudioControlsDisabled else {
            audioDiagnosticState = .failed(
                local: nil,
                message: "录音进行中无法运行音频诊断。"
            )
            return
        }
        guard let diagnosticCoordinatorFactory else {
            audioDiagnosticState = .failed(
                local: nil,
                message: "音频诊断当前不可用。"
            )
            return
        }
        guard claimAudioOperation(
            .diagnostic,
            settingsSession: settingsSession
        ) else { return }
        var shouldKeepOperationClaimed = false
        defer {
            if !shouldKeepOperationClaimed {
                releaseAudioOperation(.diagnostic)
            }
        }

        applySelectedAudioDevicesForTesting()
        diagnosticGeneration &+= 1
        let requestedGeneration = diagnosticGeneration
        await refreshAudioDevices()
        guard diagnosticGeneration == requestedGeneration,
              activeAudioOperation == .diagnostic else { return }
        audioDiagnosticState = .running(.checkingPermissions)
        let coordinator = await diagnosticCoordinatorFactory.makeCoordinator()
        guard diagnosticGeneration == requestedGeneration else {
            await coordinator.cancel()
            return
        }
        activeDiagnostic = coordinator

        do {
            audioDiagnosticState = .running(.playingOutputTone)
            try await coordinator.prepare()
            guard diagnosticGeneration == requestedGeneration else { return }
            applyCoordinatorState(await coordinator.currentState())
            shouldKeepOperationClaimed =
                audioDiagnosticState == .awaitingOutputConfirmation
        } catch {
            guard diagnosticGeneration == requestedGeneration else { return }
            audioDiagnosticState = .failed(
                local: nil,
                message: Self.diagnosticMessage(for: error)
            )
        }
    }

    func confirmOutputWasAudible(_ heardTone: Bool) async {
        await refreshAudioControlAvailability()
        guard !areAudioControlsDisabled else { return }
        guard case .awaitingOutputConfirmation = audioDiagnosticState,
              let activeDiagnostic,
              activeAudioOperation == .diagnostic else { return }
        let requestedGeneration = diagnosticGeneration
        defer {
            releaseAudioOperation(.diagnostic)
        }
        audioDiagnosticState = .running(.testingMicrophone)
        let monitor = Task { @MainActor [weak self] in
            await self?.monitorDiagnostic(
                activeDiagnostic,
                generation: requestedGeneration
            )
        }
        defer { monitor.cancel() }

        do {
            try await activeDiagnostic.continueAfterOutputConfirmation(
                heardTone: heardTone
            )
            guard diagnosticGeneration == requestedGeneration else { return }
            applyCoordinatorState(await activeDiagnostic.currentState())
        } catch {
            guard diagnosticGeneration == requestedGeneration else { return }
            audioDiagnosticState = .failed(
                local: currentDiagnosticPreview,
                message: Self.diagnosticMessage(for: error)
            )
        }
    }

    func sendDiagnosticToDeepSeek() async {
        await refreshAudioControlAvailability()
        guard !areAudioControlsDisabled else { return }
        guard let preview = currentDiagnosticPreview,
              let report = latestDiagnosticReport,
              let metadata = latestDiagnosticMetadata else { return }
        guard let diagnosticExplainer else {
            audioDiagnosticState = .failed(
                local: preview,
                message: "DeepSeek 诊断当前不可用，本地诊断仍可用。"
            )
            return
        }

        let apiKey: String
        do {
            let currentInput = deepSeekAPIKeyInput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !currentInput.isEmpty {
                apiKey = currentInput
            } else if let saved = try credentialStore.value(
                for: .deepSeekAPIKey
            ) {
                apiKey = saved
            } else {
                audioDiagnosticState = .failed(
                    local: preview,
                    message: "请输入 DeepSeek API Key，或先保存已有 Key。"
                )
                return
            }
        } catch {
            audioDiagnosticState = .failed(
                local: preview,
                message: "无法读取 API Key，本地诊断仍可用。"
            )
            return
        }

        let requestedGeneration = diagnosticGeneration
        audioDiagnosticState = .explaining(preview)
        do {
            let explanation = try await diagnosticExplainer
                .requestExplanation(
                    apiKey: apiKey,
                    report: report,
                    metadata: metadata,
                    model: selectedModel
                )
            guard diagnosticGeneration == requestedGeneration else { return }
            audioDiagnosticState = .completed(
                AudioDiagnosticPresentation(
                    local: preview,
                    issue: explanation.issue,
                    solution: explanation.solution,
                    source: explanation.source
                )
            )
        } catch {
            guard diagnosticGeneration == requestedGeneration else { return }
            audioDiagnosticState = .failed(
                local: preview,
                message: "DeepSeek 解释失败，本地诊断仍可用。"
            )
        }
    }

    func cancelAudioDiagnostic() async {
        guard !isCancellingAudioOperation else { return }
        isCancellingAudioOperation = true
        defer {
            activeAudioOperation = nil
            isCancellingAudioOperation = false
        }
        diagnosticGeneration &+= 1
        inputTestGeneration &+= 1
        outputTestGeneration &+= 1
        let coordinator = activeDiagnostic
        activeDiagnostic = nil
        await coordinator?.cancel()
        await audioInputTester?.cancel()
        await audioOutputTester?.stop()
        latestDiagnosticReport = nil
        latestDiagnosticMetadata = nil
        audioInputTestState = .idle
        audioOutputTestState = .idle
        audioDiagnosticState = .idle
    }

    func audioSettingsDidAppear() {
        audioSettingsSessionGeneration &+= 1
        isAudioSettingsVisible = true
        audioDeviceChangeObserver.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isAudioSettingsVisible else { return }
                await self.refreshAudioDevices()
            }
        }
    }

    func audioSettingsDidDisappear() {
        audioSettingsSessionGeneration &+= 1
        isAudioSettingsVisible = false
        audioDeviceChangeObserver.stop()
        guard activeAudioOperation != nil else { return }
        Task { @MainActor [weak self] in
            await self?.cancelAudioDiagnostic()
        }
    }

    private func claimAudioOperation(
        _ operation: SettingsAudioOperation,
        settingsSession: UInt64
    ) -> Bool {
        guard activeAudioOperation == nil,
              !isCancellingAudioOperation,
              isAudioSettingsVisible,
              audioSettingsSessionGeneration == settingsSession else {
            return false
        }
        activeAudioOperation = operation
        return true
    }

    private func releaseAudioOperation(
        _ operation: SettingsAudioOperation
    ) {
        guard activeAudioOperation == operation else { return }
        activeAudioOperation = nil
    }

    func testDeepSeekConnection() async {
        guard !deepSeekConnection.isTesting else { return }

        let input = deepSeekAPIKeyInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let apiKey: String
        do {
            if !input.isEmpty {
                apiKey = input
            } else if let saved = try credentialStore.value(
                for: .deepSeekAPIKey
            ) {
                apiKey = saved
            } else {
                deepSeekConnection = .failed(
                    message: "请输入 DeepSeek API Key，或先保存已有 Key。"
                )
                return
            }
        } catch {
            deepSeekConnection = .failed(
                message: "无法读取已保存的 API Key，请检查钥匙串。"
            )
            return
        }

        deepSeekConnection = .testing
        do {
            let models = try await deepSeekTester.testConnection(apiKey: apiKey)
            availableModels = Array(Set(models)).sorted()
            if availableModels.isEmpty {
                availableModels = [selectedModel]
            } else if !availableModels.contains(selectedModel),
                      let first = availableModels.first {
                selectedModel = first
            }
            deepSeekConnection = .succeeded(
                message: "连接成功，发现 \(models.count) 个模型"
            )
        } catch {
            deepSeekConnection = .failed(
                message: Self.deepSeekMessage(for: error)
            )
        }
    }

    func testNotionConnection() async {
        guard !notionConnection.isTesting else { return }

        let input = notionTokenInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token: String
        do {
            if !input.isEmpty {
                token = input
            } else if let saved = try credentialStore.value(for: .notionToken) {
                token = saved
            } else {
                notionConnection = .failed(
                    message: "请输入 Notion Token，或先保存已有 Token。"
                )
                return
            }
        } catch {
            notionConnection = .failed(
                message: "无法读取已保存的 Notion Token，请检查钥匙串。"
            )
            return
        }

        guard let parentPageID = NotionPageLinkParser.parse(
            notionParentPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            notionConnection = .failed(
                message: "请输入有效的 Notion 父页面链接。"
            )
            return
        }

        notionConnection = .testing
        do {
            let result = try await notionTester.testConnection(
                token: token,
                parentPageID: parentPageID
            )
            notionConnection = .succeeded(
                message: "连接成功：\(result.parentPageTitle)"
            )
        } catch {
            notionConnection = .failed(
                message: Self.notionMessage(for: error)
            )
        }
    }

    func clearDeepSeekCredential() {
        do {
            try credentialStore.delete(.deepSeekAPIKey)
            deepSeekAPIKeyInput = ""
            deepSeekCredential = .missing
            deepSeekConnection = .idle
        } catch {
            saveState = .failed(message: "无法清除 DeepSeek API Key。")
        }
    }

    func clearNotionCredential() {
        do {
            try credentialStore.delete(.notionToken)
            notionTokenInput = ""
            notionCredential = .missing
            notionConnection = .idle
        } catch {
            saveState = .failed(message: "无法清除 Notion Token。")
        }
    }

    private var currentDiagnosticPreview: AudioDiagnosticPreview? {
        switch audioDiagnosticState {
        case let .readyForUpload(preview),
             let .explaining(preview):
            preview
        case let .completed(presentation):
            presentation.local
        case let .failed(local, _):
            local
        case .idle, .running, .awaitingOutputConfirmation:
            nil
        }
    }

    private func receiveInputMetrics(
        _ metrics: AudioSignalMetrics,
        generation: UInt64
    ) {
        guard inputTestGeneration == generation else { return }
        audioInputTestState = .testing(metrics)
    }

    private func refreshMicrophoneRuntimeIfCurrent(
        _ generation: UInt64
    ) async {
        guard inputTestGeneration == generation,
              let microphoneRuntime else {
            return
        }
        microphoneRuntimeSnapshot =
            await microphoneRuntime.runtimeSnapshot()
    }

    private func monitorDiagnostic(
        _ coordinator: any AudioDiagnosticCoordinating,
        generation: UInt64
    ) async {
        while !Task.isCancelled, diagnosticGeneration == generation {
            let coordinatorState = await coordinator.currentState()
            guard diagnosticGeneration == generation else { return }
            switch coordinatorState {
            case .checkingPermissions:
                audioDiagnosticState = .running(.checkingPermissions)
            case .playingOutputTone:
                audioDiagnosticState = .running(.playingOutputTone)
            case .testingMicrophone:
                audioDiagnosticState = .running(.testingMicrophone)
            case .testingSystemAudio:
                audioDiagnosticState = .running(.testingSystemAudio)
            case .idle, .awaitingOutputConfirmation, .readyForUpload, .failed:
                break
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }

    private func applyCoordinatorState(
        _ coordinatorState: AudioDiagnosticCoordinatorState
    ) {
        switch coordinatorState {
        case .idle:
            audioDiagnosticState = .idle
        case .checkingPermissions:
            audioDiagnosticState = .running(.checkingPermissions)
        case .playingOutputTone:
            audioDiagnosticState = .running(.playingOutputTone)
        case .awaitingOutputConfirmation:
            audioDiagnosticState = .awaitingOutputConfirmation
        case .testingMicrophone:
            audioDiagnosticState = .running(.testingMicrophone)
        case .testingSystemAudio:
            audioDiagnosticState = .running(.testingSystemAudio)
        case let .readyForUpload(report):
            do {
                let metadata = makeDiagnosticMetadata()
                let preview = try makeDiagnosticPreview(
                    report: report,
                    metadata: metadata
                )
                latestDiagnosticReport = report
                latestDiagnosticMetadata = metadata
                audioDiagnosticState = .readyForUpload(preview)
            } catch {
                audioDiagnosticState = .failed(
                    local: nil,
                    message: "无法生成诊断预览，请重新测试。"
                )
            }
        case .failed:
            audioDiagnosticState = .failed(
                local: currentDiagnosticPreview,
                message: "音频诊断未完成，请检查权限与设备后重试。"
            )
        }
    }

    private func makeDiagnosticPreview(
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata
    ) throws -> AudioDiagnosticPreview {
        let envelope = diagnosticSanitizer.makeEnvelope(
            report: report,
            metadata: metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let allowlistedJSON = String(
            decoding: try encoder.encode(envelope),
            as: UTF8.self
        )
        return AudioDiagnosticPreview(
            primaryIssue: report.primaryIssue,
            supportingIssues: report.supportingIssues,
            localIssue: report.localIssue,
            localSolution: report.localSolution,
            allowlistedJSON: allowlistedJSON
        )
    }

    private func makeDiagnosticMetadata() -> AudioDiagnosticUploadMetadata {
        let environment = diagnosticEnvironment.environmentInfo()
        return AudioDiagnosticUploadMetadata(
            appVersion: environment.appVersion,
            hardwareModel: environment.hardwareModel,
            macOSVersion: environment.macOSVersion,
            inputDevice: diagnosticInputDeviceMetadata(),
            outputDevice: diagnosticOutputDeviceMetadata(),
            apiErrorCategory: nil
        )
    }

    private func diagnosticInputDeviceMetadata()
        -> AudioDiagnosticDeviceMetadata {
        switch resolvedInputDevice {
        case let .preferred(device):
            return inputMetadata(device, status: .selected)
        case let .systemDefault(device), let .firstUsable(device):
            return inputMetadata(device, status: .automatic)
        case let .fallback(selected, _):
            return inputMetadata(selected, status: .fallback)
        case .unavailable:
            return AudioDiagnosticDeviceMetadata(
                name: nil,
                status: .unavailable
            )
        }
    }

    private func diagnosticOutputDeviceMetadata()
        -> AudioDiagnosticDeviceMetadata {
        switch resolvedOutputDevice {
        case let .preferred(device):
            return outputMetadata(device, status: .selected)
        case let .systemDefault(device), let .firstUsable(device):
            return outputMetadata(device, status: .automatic)
        case let .fallback(selected, _):
            return outputMetadata(selected, status: .fallback)
        case .unavailable:
            return AudioDiagnosticDeviceMetadata(
                name: nil,
                status: .unavailable
            )
        }
    }

    private func inputMetadata(
        _ device: AudioInputDevice,
        status: AudioDiagnosticDeviceStatus
    ) -> AudioDiagnosticDeviceMetadata {
        AudioDiagnosticDeviceMetadata(
            name: device.name,
            status: status,
            isConnected: device.isConnected,
            isSystemDefault: device.isSystemDefault,
            isInUseByAnotherApplication:
                device.isInUseByAnotherApplication
        )
    }

    private func outputMetadata(
        _ device: AudioOutputDevice,
        status: AudioDiagnosticDeviceStatus
    ) -> AudioDiagnosticDeviceMetadata {
        AudioDiagnosticDeviceMetadata(
            name: device.name,
            status: status,
            isConnected: device.isConnected,
            isSystemDefault: device.isSystemDefault,
            isInUseByAnotherApplication: false
        )
    }

    private func applySelectedAudioDevicesForTesting() {
        settingsStore.preferredAudioInput = Self.preferredAudioInput(
            selectedID: selectedInputDeviceID,
            inputs: audioDevices.inputs
        )
        settingsStore.preferredOutputDeviceID = selectedOutputDeviceID
    }

    private static func preferredAudioInput(
        selectedID: String?,
        inputs: [AudioInputDevice]
    ) -> PreferredAudioInput {
        guard let selectedID else {
            return .automatic
        }
        guard let device = inputs.first(where: {
                  $0.id == selectedID
                    || $0.avFoundationUniqueID == selectedID
                    || $0.coreAudioUID == selectedID
              }) else {
            return PreferredAudioInput(
                backend: .automatic,
                stableID: selectedID,
                legacyAVFoundationID: selectedID,
                coreAudioUID: nil
            )
        }
        return PreferredAudioInput(
            backend: .automatic,
            stableID: device.stableID,
            legacyAVFoundationID: device.avFoundationUniqueID,
            coreAudioUID: device.coreAudioUID
        )
    }

    private static func resolvedInputDevice(
        from resolution: ResolvedMicrophoneCapture?
    ) -> ResolvedAudioDevice<AudioInputDevice> {
        guard let resolution else { return .unavailable }
        switch resolution.kind {
        case .preferred:
            return .preferred(resolution.device)
        case .systemDefault:
            return .systemDefault(resolution.device)
        case .firstUsable:
            return .firstUsable(resolution.device)
        case let .fallback(unavailablePreferredID):
            return .fallback(
                selected: resolution.device,
                unavailablePreferredID: unavailablePreferredID
            )
        }
    }

    private static func diagnosticMessage(for error: Error) -> String {
        switch error as? AudioDiagnosticCoordinatorError {
        case .recordingActive:
            "录音进行中无法运行音频诊断。"
        case .timedOut:
            "音频诊断超时，请检查设备连接后重试。"
        case .insufficientEvidence:
            "没有获得足够的音频证据，请重新运行诊断。"
        case .invalidState, nil:
            "音频诊断未完成，请检查权限与设备后重试。"
        }
    }

    private func refreshCredentialPresence() throws {
        deepSeekCredential = try presence(for: .deepSeekAPIKey)
        notionCredential = try presence(for: .notionToken)
    }

    private func presence(for key: CredentialKey) throws -> CredentialPresence {
        guard let value = try credentialStore.value(for: key) else {
            return .missing
        }
        return .saved(maskedValue: CredentialMask.mask(value))
    }

    private static func audioDeviceMessage(
        input: ResolvedAudioDevice<AudioInputDevice>,
        output: ResolvedAudioDevice<AudioOutputDevice>,
        usesCoreAudioFallback: Bool,
        isRecovering: Bool
    ) -> String? {
        var messages: [String] = []

        switch input {
        case let .fallback(selected, _):
            messages.append(
                "已保存的麦克风不可用，已临时使用“\(selected.name)”。"
            )
        case .unavailable:
            messages.append("没有可用的麦克风。")
        default:
            break
        }

        switch output {
        case let .fallback(selected, _):
            messages.append(
                "已保存的扬声器不可用，已临时使用“\(selected.name)”。"
            )
        case .unavailable:
            messages.append("没有可用的扬声器。")
        default:
            break
        }

        if usesCoreAudioFallback {
            messages.append("已启用兼容录音模式（Core Audio）。")
        }
        if isRecovering {
            messages.append("正在重新连接麦克风…")
        }

        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private static func deepSeekMessage(for error: Error) -> String {
        switch error as? DeepSeekClientError {
        case .unauthorized:
            "API Key 无效或无权限，请检查后重试。"
        case .rateLimited:
            "DeepSeek 请求过于频繁，请稍后重试。"
        case .timeout:
            "DeepSeek 连接超时，请检查网络后重试。"
        case .serviceUnavailable, .server:
            "DeepSeek 服务暂时不可用，请稍后重试。"
        case .transport:
            "无法连接 DeepSeek，请检查网络。"
        default:
            "DeepSeek 返回了无法识别的响应，请稍后重试。"
        }
    }

    private static func notionMessage(for error: Error) -> String {
        switch error as? NotionClientError {
        case .unauthorized:
            "Notion Token 无效，请检查后重试。"
        case .forbidden:
            "集成无权访问该页面，请在 Notion 中共享页面给集成。"
        case .pageNotFound:
            "找不到该 Notion 页面，请检查链接和共享权限。"
        case .rateLimited:
            "Notion 请求过于频繁，请稍后重试。"
        case .timeout:
            "Notion 连接超时，请检查网络后重试。"
        case .server:
            "Notion 服务暂时不可用，请稍后重试。"
        case .transport:
            "无法连接 Notion，请检查网络。"
        default:
            "Notion 返回了无法识别的响应，请稍后重试。"
        }
    }
}
