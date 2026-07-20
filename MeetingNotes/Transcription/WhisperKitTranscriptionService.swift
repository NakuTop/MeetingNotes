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
    private let modelFolder: URL?
    private var whisperKit: WhisperKit?
    private var preparationInProgress = false
    private var preparationWaiters: [CheckedContinuation<Void, Error>] = []

    init(model: String? = nil, modelFolder: URL? = nil) {
        self.model = model
        self.modelFolder = modelFolder
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
            let configuration = WhisperKitConfig(
                model: model,
                modelFolder: modelFolder?.path,
                verbose: false,
                prewarm: true,
                load: true
            )
            whisperKit = try await WhisperKit(configuration)
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
