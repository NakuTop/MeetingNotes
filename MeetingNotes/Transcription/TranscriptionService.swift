import Foundation

enum TranscriptAudioSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
    case room
}

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

struct AttributedTranscriptDraft: Equatable, Sendable {
    let transcript: TranscriptDraft
    let speakerID: String?
    let source: TranscriptAudioSource
}

protocol TranscriptionService: Sendable {
    func prepare() async throws

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft]
}
