import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionService:
    TranscriptionService,
    TranscriptionModelPreparing {
    static let sampleRate = 16_000.0

    private let model: String?
    private var whisperKit: WhisperKit?
    private var preparationInProgress = false
    private var preparationWaiters: [CheckedContinuation<Void, Error>] = []

    init(model: String? = nil) {
        self.model = model
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

        let results = try await whisperKit.transcribe(audioArray: samples)
        var drafts: [TranscriptDraft] = []
        for result in results {
            if result.segments.isEmpty {
                let text = result.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !text.isEmpty {
                    drafts.append(
                        TranscriptDraft(
                            startTime: startingAt,
                            endTime: startingAt
                                + Double(samples.count) / Self.sampleRate,
                            text: text
                        )
                    )
                }
                continue
            }

            drafts.append(contentsOf: result.segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !text.isEmpty else {
                    return nil
                }
                return TranscriptDraft(
                    startTime: startingAt + Double(segment.start),
                    endTime: startingAt + Double(segment.end),
                    text: text
                )
            })
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
