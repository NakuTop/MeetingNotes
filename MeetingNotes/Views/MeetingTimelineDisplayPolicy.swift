import Foundation

struct MeetingNoteDisplayItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let text: String
    let sequenceIndex: Int

    init(
        id: UUID,
        timestamp: TimeInterval,
        text: String,
        sequenceIndex: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.sequenceIndex = sequenceIndex
    }

    init(record: MeetingNoteRecord) {
        self.init(
            id: record.id,
            timestamp: record.timestamp,
            text: record.text,
            sequenceIndex: record.sequenceIndex
        )
    }
}

struct MeetingScreenshotDisplayItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let relativePath: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let sequenceIndex: Int

    init(
        id: UUID,
        timestamp: TimeInterval,
        relativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sequenceIndex: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sequenceIndex = sequenceIndex
    }

    init(record: MeetingScreenshotRecord) {
        self.init(
            id: record.id,
            timestamp: record.timestamp,
            relativePath: record.relativePath,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            byteCount: record.byteCount,
            sequenceIndex: record.sequenceIndex
        )
    }
}

enum MeetingTimelineDisplayItem: Identifiable, Equatable {
    case transcript(TranscriptDisplayTurn)
    case note(MeetingNoteDisplayItem)
    case screenshot(MeetingScreenshotDisplayItem)

    var id: UUID {
        switch self {
        case let .transcript(turn): turn.id
        case let .note(note): note.id
        case let .screenshot(screenshot): screenshot.id
        }
    }

    var timestamp: TimeInterval {
        switch self {
        case let .transcript(turn): turn.startTime
        case let .note(note): note.timestamp
        case let .screenshot(screenshot): screenshot.timestamp
        }
    }
}

@MainActor
enum MeetingTimelineDisplayPolicy {
    static func items(
        transcriptTurns: [TranscriptDisplayTurn],
        notes: [MeetingNoteRecord],
        screenshots: [MeetingScreenshotRecord]
    ) -> [MeetingTimelineDisplayItem] {
        var rankedItems = transcriptTurns.enumerated().map { index, turn in
            RankedItem(
                item: .transcript(turn),
                sequenceIndex: index,
                kindRank: 0
            )
        }
        rankedItems += notes.map { note in
            RankedItem(
                item: .note(MeetingNoteDisplayItem(record: note)),
                sequenceIndex: max(0, note.sequenceIndex),
                kindRank: 1
            )
        }
        rankedItems += screenshots.map { screenshot in
            RankedItem(
                item: .screenshot(
                    MeetingScreenshotDisplayItem(record: screenshot)
                ),
                sequenceIndex: max(0, screenshot.sequenceIndex),
                kindRank: 2
            )
        }

        return rankedItems.sorted(by: comesBefore).map(\.item)
    }

    private static func comesBefore(
        _ lhs: RankedItem,
        _ rhs: RankedItem
    ) -> Bool {
        let lhsTimestamp = sanitized(lhs.item.timestamp)
        let rhsTimestamp = sanitized(rhs.item.timestamp)
        if lhsTimestamp != rhsTimestamp {
            return lhsTimestamp < rhsTimestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        if lhs.kindRank != rhs.kindRank {
            return lhs.kindRank < rhs.kindRank
        }
        return lhs.item.id.uuidString < rhs.item.id.uuidString
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private struct RankedItem {
        let item: MeetingTimelineDisplayItem
        let sequenceIndex: Int
        let kindRank: Int
    }
}
