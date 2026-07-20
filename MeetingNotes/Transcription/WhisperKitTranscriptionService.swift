import Foundation
@preconcurrency import WhisperKit

enum WhisperDecodingPolicy {
    static var options: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            skipSpecialTokens: true
        )
    }
}

enum WhisperLanguagePolicy {
    private static let supportedLanguages: Set<String> = ["zh", "en"]

    static func accepts(language: String) -> Bool {
        supportedLanguages.contains(language)
    }
}

struct WhisperTranscriptSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum WhisperTranscriptDraftBuilder {
    static func makeDrafts(
        resultLanguage: String,
        resultText: String,
        segments: [WhisperTranscriptSegment],
        sampleCount: Int,
        startingAt: TimeInterval
    ) -> [TranscriptDraft] {
        guard WhisperLanguagePolicy.accepts(language: resultLanguage) else {
            return []
        }
        if segments.isEmpty {
            guard let text = TranscriptTextSanitizer.nonEmpty(resultText) else {
                return []
            }
            return [
                TranscriptDraft(
                    startTime: startingAt,
                    endTime: startingAt
                        + Double(sampleCount)
                        / WhisperKitTranscriptionService.sampleRate,
                    text: text
                )
            ]
        }

        return segments.compactMap { segment in
            guard let text = TranscriptTextSanitizer.nonEmpty(segment.text) else {
                return nil
            }
            return TranscriptDraft(
                startTime: startingAt + segment.start,
                endTime: startingAt + segment.end,
                text: text
            )
        }
    }
}

actor WhisperKitTranscriptionService:
    TranscriptionService,
    TranscriptionModelPreparing {
    static let sampleRate = 16_000.0

    private let model: String?
    private let persistentModelFolder: URL?
    private var whisperKit: WhisperKit?
    private var preparationInProgress = false
    private var preparationWaiters: [CheckedContinuation<Void, Error>] = []

    init(model: String? = nil, persistentModelFolder: URL? = nil) {
        self.model = model
        self.persistentModelFolder = persistentModelFolder
    }

    func prepare() async throws {
        guard whisperKit == nil else {
            return
        }
        if preparationInProgress {
            return try await withCheckedThrowingContinuation { continuation in
                preparationWaiters.append(continuation)
            }
        }

        preparationInProgress = true
        do {
            if let folder = persistentModelFolder,
               hasModelFiles(at: folder) {
                // Model already cached locally — load offline
                let config = WhisperKitConfig(
                    modelFolder: folder.path,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
                whisperKit = try await WhisperKit(config)
            } else {
                // First launch — download to Hub cache, then persist
                let config = WhisperKitConfig(
                    model: model,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true
                )
                whisperKit = try await WhisperKit(config)
                // Copy downloaded model to persistent folder for offline use
                if let folder = persistentModelFolder,
                   let downloadedPath = whisperKit?.modelFolder {
                    try? copyModel(from: downloadedPath, to: folder)
                }
            }
            finishPreparation(with: .success(()))
        } catch {
            finishPreparation(with: .failure(error))
            throw error
        }
    }

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        if whisperKit == nil {
            try await prepare()
        }
        guard let whisperKit else {
            return []
        }

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: WhisperDecodingPolicy.options
        )
        var drafts: [TranscriptDraft] = []
        for result in results {
            drafts.append(
                contentsOf: WhisperTranscriptDraftBuilder.makeDrafts(
                    resultLanguage: result.language,
                    resultText: result.text,
                    segments: result.segments.map {
                        WhisperTranscriptSegment(
                            start: Double($0.start),
                            end: Double($0.end),
                            text: $0.text
                        )
                    },
                    sampleCount: samples.count,
                    startingAt: startingAt
                )
            )
        }
        return TranscriptMerger().merge(drafts)
    }

    private func hasModelFiles(at folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return false }
        guard let contents = try? fm.contentsOfDirectory(atPath: folder.path),
              !contents.isEmpty else { return false }
        return contents.contains { $0.hasSuffix(".mlmodelc") || $0 == "config.json" || $0 == "model.mlpackage" }
    }

    private func copyModel(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(atPath: source.path)
        for item in contents {
            let src = source.appendingPathComponent(item)
            let dst = destination.appendingPathComponent(item)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }
    }

    private func finishPreparation(with result: Result<Void, Error>) {
        preparationInProgress = false
        let waiters = preparationWaiters
        preparationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            switch result {
            case .success:
                waiter.resume()
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }
    }
}
