import Foundation
import SwiftData

@Model
final class MeetingScreenshotRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: TimeInterval
    var relativePath: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var createdAt: Date
    var sequenceIndex: Int
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        relativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        createdAt: Date = .now,
        sequenceIndex: Int,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.sequenceIndex = sequenceIndex
        self.meeting = meeting
    }
}
