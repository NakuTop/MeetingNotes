import Foundation

struct TranscriptDraft: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

protocol TranscriptionService: Sendable {
    func prepare() async throws

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft]
}
