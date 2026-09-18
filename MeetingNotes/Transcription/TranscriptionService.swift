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
    let words: [TranscriptWordTiming]

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        words: [TranscriptWordTiming] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
    }
}

struct AttributedTranscriptDraft: Equatable, Sendable {
    let transcript: TranscriptDraft
    let speakerID: String?
    let source: TranscriptAudioSource
    var attributionStatus: SpeakerAttributionStatus? = nil
    var sourceEvidence: SpeakerSourceEvidence? = nil
    // Ephemeral lineage lets persistence preserve edits made while inference
    // was running. It is never an instruction to change the user's text.
    var attributionOrigin: TranscriptAttributionOrigin? = nil
    var automaticSpeakerID: String? = nil
    var automaticAttributionStatus: SpeakerAttributionStatus? = nil
    var reviewHint: SpeakerReviewHint? = nil
}

enum SpeakerAttributionStatus: String, Codable, Sendable {
    case manuallyAssigned
    case attributed
    // Best-effort automatic attribution, not a verified identity/confidence claim.
    case inferred
    case uncertain
    case overlapping
}

struct TranscriptAttributionOrigin: Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct TranscriptWordTiming: Codable, Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

protocol TranscriptionService: Sendable {
    func prepare() async throws

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft]
}
