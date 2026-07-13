import Foundation

struct CapturedAudioFrame: Equatable, Sendable {
    let timestamp: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]

    init(
        timestamp: TimeInterval,
        sampleRate: Double,
        channelCount: Int = 1,
        samples: [Float]
    ) {
        self.timestamp = timestamp
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }
}
