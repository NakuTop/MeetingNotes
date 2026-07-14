import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionService: TranscriptionService {
    static let sampleRate = 16_000.0

    private let model: String?
    private var whisperKit: WhisperKit?

    init(model: String? = nil) {
        self.model = model
    }

    func prepare() async throws {
        guard whisperKit == nil else {
            return
        }
        let configuration = WhisperKitConfig(
            model: model,
            verbose: false,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(configuration)
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
}
