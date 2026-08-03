import Observation

enum TranscriptionModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading
    case ready
    case failed

    var allowsRecording: Bool { true }

    var displaysRealtimeTranscription: Bool {
        self == .ready
    }
}

protocol TranscriptionModelPreparing: Sendable {
    func prepare() async throws
}

private actor LegacyTranscriptionModelControllerAdapter:
    TranscriptionModelStatusControlling {
    private let preparer: any TranscriptionModelPreparing
    private var statuses: [
        TranscriptionQualityMode: TranscriptionModelStatus
    ] = [:]

    init(preparer: any TranscriptionModelPreparing) {
        self.preparer = preparer
    }

    func status(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelStatus {
        statuses[mode] ?? .notDownloaded
    }

    func prepare(mode: TranscriptionQualityMode) async throws {
        statuses[mode] = .downloading
        do {
            try await preparer.prepare()
            statuses[mode] = .ready
        } catch {
            statuses[mode] = .failed
            throw error
        }
    }
}

@MainActor
@Observable
final class TranscriptionModelViewModel {
    private let controller: any TranscriptionModelStatusControlling
    private var statuses: [
        TranscriptionQualityMode: TranscriptionModelStatus
    ]

    var selectedMode: TranscriptionQualityMode

    init(
        controller: any TranscriptionModelStatusControlling,
        selectedMode: TranscriptionQualityMode = .balanced
    ) {
        self.controller = controller
        self.selectedMode = selectedMode
        statuses = Dictionary(
            uniqueKeysWithValues: TranscriptionQualityMode.allCases.map {
                ($0, .notDownloaded)
            }
        )
    }

    convenience init(
        preparer: any TranscriptionModelPreparing,
        selectedMode: TranscriptionQualityMode = .balanced
    ) {
        self.init(
            controller: LegacyTranscriptionModelControllerAdapter(
                preparer: preparer
            ),
            selectedMode: selectedMode
        )
    }

    var selectedStatus: TranscriptionModelStatus {
        status(for: selectedMode)
    }

    var selectedDescriptor: TranscriptionModelDescriptor {
        descriptor(for: selectedMode)
    }

    var canDownloadSelected: Bool {
        canDownload(mode: selectedMode)
    }

    // Compatibility for the start screen and existing onboarding tests.
    var status: TranscriptionModelStatus {
        selectedStatus
    }

    var canRetry: Bool {
        canRetry(mode: selectedMode)
    }

    func descriptor(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelDescriptor {
        TranscriptionModelCatalog.descriptor(for: mode)
    }

    func status(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelStatus {
        statuses[mode] ?? .notDownloaded
    }

    func canDownload(mode: TranscriptionQualityMode) -> Bool {
        status(for: mode) == .notDownloaded
    }

    func canRetry(mode: TranscriptionQualityMode) -> Bool {
        status(for: mode) == .failed
    }

    func canPersistSelection(mode: TranscriptionQualityMode) -> Bool {
        mode == .balanced || status(for: mode) == .ready
    }

    func refreshStatuses() async {
        for mode in TranscriptionQualityMode.allCases {
            statuses[mode] = await controller.status(for: mode)
        }
    }

    func prepareBalancedIfNeeded() async {
        await prepareIfNeeded(mode: .balanced, allowsRetry: true)
    }

    func downloadSelected() async {
        await download(mode: selectedMode)
    }

    func retrySelected() async {
        await retry(mode: selectedMode)
    }

    func download(mode: TranscriptionQualityMode) async {
        await prepareIfNeeded(mode: mode, allowsRetry: false)
    }

    func retry(mode: TranscriptionQualityMode) async {
        guard status(for: mode) == .failed else { return }
        await prepare(mode: mode)
    }

    func prepareIfNeeded() async {
        await prepareIfNeeded(mode: selectedMode, allowsRetry: true)
    }

    func retry() async {
        await retrySelected()
    }

    private func prepareIfNeeded(
        mode: TranscriptionQualityMode,
        allowsRetry: Bool
    ) async {
        let current = status(for: mode)
        guard current == .notDownloaded
                || (allowsRetry && current == .failed) else {
            return
        }
        await prepare(mode: mode)
    }

    private func prepare(mode: TranscriptionQualityMode) async {
        statuses[mode] = .downloading
        do {
            try await controller.prepare(mode: mode)
            statuses[mode] = .ready
        } catch {
            statuses[mode] = .failed
        }
    }
}
