import Foundation

struct CapturedAudioFrame: Equatable, Sendable {
    let timestamp: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]
    let transcriptionSamples: [Float]?
    let transcriptionSampleRate: Double?

    init(
        timestamp: TimeInterval,
        sampleRate: Double,
        channelCount: Int = 1,
        samples: [Float],
        transcriptionSamples: [Float]? = nil,
        transcriptionSampleRate: Double? = nil
    ) {
        self.timestamp = timestamp
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
        self.transcriptionSamples = transcriptionSamples
        self.transcriptionSampleRate = transcriptionSampleRate
    }
}
