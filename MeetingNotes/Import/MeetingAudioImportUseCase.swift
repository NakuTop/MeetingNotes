import Foundation

enum MeetingAudioImportProgress: Equatable, Sendable {
    case converting(Double)
    case preparingModel
    case transcribing(TimeInterval, duration: TimeInterval)
    case identifyingSpeakers

    var message: String {
        switch self {
        case let .converting(fraction): "正在导入本地录音 · \(Int(fraction * 100))%"
        case .preparingModel: "录音已保存，正在准备本地转录模型…"
        case let .transcribing(time, duration): "正在转录本地录音 · \(Int(time)) / \(Int(duration)) 秒"
        case .identifyingSpeakers: "正在识别录音中的说话人…"
        }
    }
}

protocol MeetingAudioImportCoordinating: Sendable {
    func beginAudioImport() async throws
    func endAudioImport() async
}

extension MeetingCoordinator: MeetingAudioImportCoordinating {}

@MainActor
protocol MeetingAudioImporting: AnyObject {
    func importRecording(from url: URL, onCreated: (UUID) -> Void,
                         onProgress: @escaping @MainActor @Sendable (MeetingAudioImportProgress) -> Void) async throws -> UUID
    func retryTranscription(meetingID: UUID,
                            onProgress: @escaping @MainActor @Sendable (MeetingAudioImportProgress) -> Void) async throws
}

@MainActor
final class MeetingAudioImportUseCase: MeetingAudioImporting {
    private let repository: MeetingRepository
    private let fileStore: MeetingFileStore
    private let settings: AppSettingsStore
    private let coordinator: any MeetingAudioImportCoordinating
    private let operationGate: MeetingOperationGate
    private let fileImporter: any LocalAudioFileImporting
    private let serviceProvider: any PreferredTranscriptionServiceProviding
    private let reader: any MeetingTrackAudioReading
    private let finalizer: any MeetingSpeakerFinalizing

    init(repository: MeetingRepository, fileStore: MeetingFileStore, settings: AppSettingsStore,
         coordinator: any MeetingAudioImportCoordinating, operationGate: MeetingOperationGate,
         serviceProvider: any PreferredTranscriptionServiceProviding, reader: any MeetingTrackAudioReading,
         finalizer: any MeetingSpeakerFinalizing, fileImporter: any LocalAudioFileImporting = LocalAudioFileImporter()) {
        self.repository = repository
        self.fileStore = fileStore
        self.settings = settings
        self.coordinator = coordinator
        self.operationGate = operationGate
        self.serviceProvider = serviceProvider
        self.reader = reader
        self.finalizer = finalizer
        self.fileImporter = fileImporter
    }

    func importRecording(from url: URL, onCreated: (UUID) -> Void,
                         onProgress: @escaping @MainActor @Sendable (MeetingAudioImportProgress) -> Void) async throws -> UUID {
        try await coordinator.beginAudioImport()
        let id = UUID()
        var persisted = false
        do {
            onProgress(.converting(0))
            let manifest = try await fileImporter.convert(url, meetingID: id, fileStore: fileStore) { fraction in
                await onProgress(.converting(fraction))
            }
            try Task.checkCancellation()
            let duration = manifest.segments.last?.endTime ?? 0
            let title = MeetingTitlePolicy.canonicalize(url.deletingPathExtension().lastPathComponent)
            try repository.createMeeting(id: id, mode: .offline, startedAt: .now,
                title: title.isEmpty ? "导入的录音" : title,
                audioManifestPath: "\(id.uuidString)/manifest.json",
                speakerDiarizationRequested: settings.isSpeakerDiarizationEnabled)
            persisted = true
            try repository.saveImportedRecordingState(id: id, duration: duration, state: .finalizing, errorCode: "audio_import_processing")
            onCreated(id)
            try await transcribe(meetingID: id, onProgress: onProgress)
            await coordinator.endAudioImport()
            return id
        } catch {
            if !persisted { try? await fileStore.deleteMeetingDirectory(for: id) }
            await coordinator.endAudioImport()
            throw error
        }
    }

    func retryTranscription(meetingID: UUID,
                            onProgress: @escaping @MainActor @Sendable (MeetingAudioImportProgress) -> Void) async throws {
        try await coordinator.beginAudioImport()
        do {
            let meeting = try repository.meeting(id: meetingID)
            guard meeting.lastErrorCode?.hasPrefix("audio_import_") == true,
                  meeting.mode == .offline, meeting.state == .ready else {
                throw MeetingCoordinatorError.operationInProgress
            }
            try await transcribe(meetingID: meetingID, onProgress: onProgress)
            await coordinator.endAudioImport()
        } catch {
            await coordinator.endAudioImport()
            throw error
        }
    }

    private func transcribe(meetingID: UUID,
                            onProgress: @escaping @MainActor @Sendable (MeetingAudioImportProgress) -> Void) async throws {
        guard operationGate.acquire(.audioImport, for: meetingID) else { throw MeetingCoordinatorError.operationInProgress }
        defer { operationGate.release(.audioImport, for: meetingID) }
        let meeting = try repository.meeting(id: meetingID)
        let duration = meeting.activeDuration
        do {
            try repository.saveImportedRecordingState(id: meetingID, duration: duration, state: .finalizing, errorCode: "audio_import_processing")
            onProgress(.preparingModel)
            let service = try await serviceProvider.service()
            try Task.checkCancellation()
            let chunks = try await reader.chunks(meetingID: meetingID, track: .master)
            var drafts: [TranscriptDraft] = []
            for try await chunk in chunks {
                try Task.checkCancellation()
                onProgress(.transcribing(chunk.startingAt, duration: duration))
                drafts.append(contentsOf: try await service.transcribe(samples: chunk.samples, startingAt: chunk.startingAt))
            }
            try Task.checkCancellation()
            drafts = TranscriptMerger().merge(drafts)
            // Persist text before speaker analysis so a model or diarization failure cannot lose it.
            var attributed = drafts.map { AttributedTranscriptDraft(transcript: $0, speakerID: nil, source: .room) }
            let revision = (meeting.transcripts.map(\.sourceRevision).max() ?? 0) + 1
            try repository.replaceTranscripts(meetingID: meetingID, drafts: attributed, sourceRevision: revision)
            var degradation: String?
            if meeting.speakerDiarizationRequested, !drafts.isEmpty {
                onProgress(.identifyingSpeakers)
                try repository.markSpeakerProcessingStarted(meetingID: meetingID)
                let outcome = await finalizer.finalize(meetingID: meetingID, mode: .offline,
                    diarizationRequested: true, provisional: drafts, transcriptionService: service)
                try Task.checkCancellation()
                switch outcome {
                case .unchanged: break
                case let .replacement(replacement, _): attributed = replacement
                case let .degraded(replacement, _, code):
                    if let replacement { attributed = replacement }
                    degradation = code
                }
                try repository.replaceTranscripts(meetingID: meetingID, drafts: attributed, sourceRevision: revision)
            }
            try repository.saveImportedRecordingState(id: meetingID, duration: duration, state: .ready,
                speakerErrorCode: degradation)
            // Empty/silent audio remains playable and does not masquerade as a successful transcript.
            if drafts.isEmpty { throw LocalAudioImportError.noSpeech }
        } catch {
            try repository.saveImportedRecordingState(id: meetingID, duration: duration, state: .ready,
                errorCode: "audio_import_transcription_failed")
            if error is CancellationError { throw CancellationError() }
            if case LocalAudioImportError.noSpeech = error { throw LocalAudioImportError.noSpeech }
            throw LocalAudioImportError.processingFailed
        }
    }
}
