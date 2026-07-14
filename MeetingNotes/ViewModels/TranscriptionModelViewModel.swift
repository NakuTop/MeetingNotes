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

@MainActor
@Observable
final class TranscriptionModelViewModel {
    private let preparer: any TranscriptionModelPreparing

    private(set) var status: TranscriptionModelStatus = .notDownloaded

    init(preparer: any TranscriptionModelPreparing) {
        self.preparer = preparer
    }

    var canRetry: Bool {
        status == .failed
    }

    func prepareIfNeeded() async {
        guard status == .notDownloaded || status == .failed else { return }
        status = .downloading
        do {
            try await preparer.prepare()
            status = .ready
        } catch {
            status = .failed
        }
    }

    func retry() async {
        guard canRetry else { return }
        await prepareIfNeeded()
    }
}
