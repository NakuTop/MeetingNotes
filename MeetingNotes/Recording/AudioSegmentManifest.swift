import Foundation

struct AudioSegmentManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let transcriptionSampleRate = 16_000.0
    static let transcriptionChannelCount = 1

    var version: Int
    var sampleRate: Double
    var channelCount: Int
    var segments: [Segment]

    init(
        version: Int = currentVersion,
        sampleRate: Double = transcriptionSampleRate,
        channelCount: Int = transcriptionChannelCount,
        segments: [Segment] = []
    ) {
        self.version = version
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.segments = segments
    }

    struct Segment: Codable, Equatable, Sendable {
        var fileName: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var frameCount: Int64
        var isComplete: Bool

        init(
            fileName: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            frameCount: Int64,
            isComplete: Bool
        ) {
            self.fileName = fileName
            self.startTime = startTime
            self.endTime = endTime
            self.frameCount = frameCount
            self.isComplete = isComplete
        }
    }
}
