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

struct TranscriptSpeakerOption: Identifiable, Equatable {
    let speakerID: String
    let badge: TranscriptSpeakerBadge

    var id: String { speakerID }
}

struct MeetingTimelineProjectionVersion: Equatable, Sendable {
    let contentRevision: Int
    let draftBoundaryRevision: Int
}

struct MeetingTimelineProjectionSnapshot: Equatable {
    let visibleTurns: [TranscriptDisplayTurn]
    let timelineItems: [MeetingTimelineDisplayItem]
    let speakerOptions: [TranscriptSpeakerOption]

    static let empty = MeetingTimelineProjectionSnapshot(
        visibleTurns: [],
        timelineItems: [],
        speakerOptions: []
    )
}

@MainActor
final class MeetingTimelineProjectionCache {
    private struct BookmarkValue: Equatable {
        let id: UUID
        let timestamp: TimeInterval
    }

    private struct NoteValue: Equatable {
        let id: UUID
        let timestamp: TimeInterval
        let text: String
        let sequenceIndex: Int
    }

    private struct ScreenshotValue: Equatable {
        let id: UUID
        let timestamp: TimeInterval
        let relativePath: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let sequenceIndex: Int
    }

    private struct Input: Equatable {
        let transcripts: [CanonicalTranscriptEntry]
        let bookmarks: [BookmarkValue]
        let notes: [NoteValue]
        let screenshots: [ScreenshotValue]
        let customSpeakerNames: [String: String]
        let preservingDraftTargets: [MeetingTranscriptEditTarget]
    }

    private struct CachedProjection {
        let version: MeetingTimelineProjectionVersion
        let input: Input
        let snapshot: MeetingTimelineProjectionSnapshot
    }

    private var cached: CachedProjection?
    private(set) var fullRebuildCount = 0
    private(set) var incrementalAppendCount = 0
    private(set) var cacheHitCount = 0

    func snapshot(
        version: MeetingTimelineProjectionVersion,
        transcripts: [CanonicalTranscriptEntry],
        bookmarks: [BookmarkRecord],
        notes: [MeetingNoteRecord],
        screenshots: [MeetingScreenshotRecord],
        customSpeakerNames: [String: String] = [:],
        preservingDraftTargets: [MeetingTranscriptEditTarget] = []
    ) -> MeetingTimelineProjectionSnapshot {
        let input = Input(
            transcripts: transcripts,
            bookmarks: bookmarks.map {
                BookmarkValue(id: $0.id, timestamp: $0.timestamp)
            },
            notes: notes.map {
                NoteValue(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    text: $0.text,
                    sequenceIndex: $0.sequenceIndex
                )
            },
            screenshots: screenshots.map {
                ScreenshotValue(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    relativePath: $0.relativePath,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    byteCount: $0.byteCount,
                    sequenceIndex: $0.sequenceIndex
                )
            },
            customSpeakerNames: customSpeakerNames,
            preservingDraftTargets: preservingDraftTargets
        )

        if let cached,
           cached.version == version,
           cached.input == input {
            cacheHitCount += 1
            return cached.snapshot
        }

        let result: MeetingTimelineProjectionSnapshot
        if let cached,
           cached.version.draftBoundaryRevision
                == version.draftBoundaryRevision,
           let incremental = incrementalSnapshot(
               cached: cached,
               input: input,
               bookmarks: bookmarks,
               notes: notes,
               screenshots: screenshots
           ) {
            incrementalAppendCount += 1
            result = incremental
        } else {
            fullRebuildCount += 1
            result = fullSnapshot(
                input: input,
                bookmarks: bookmarks,
                notes: notes,
                screenshots: screenshots
            )
        }

        cached = CachedProjection(
            version: version,
            input: input,
            snapshot: result
        )
        return result
    }

    private func fullSnapshot(
        input: Input,
        bookmarks: [BookmarkRecord],
        notes: [MeetingNoteRecord],
        screenshots: [MeetingScreenshotRecord]
    ) -> MeetingTimelineProjectionSnapshot {
        let turns = TranscriptDisplayPolicy.turns(
            from: input.transcripts,
            bookmarks: bookmarks,
            preservingDraftTargets: input.preservingDraftTargets
        )
        return makeSnapshot(
            turns: turns,
            notes: notes,
            screenshots: screenshots,
            customSpeakerNames: input.customSpeakerNames
        )
    }

    private func incrementalSnapshot(
        cached: CachedProjection,
        input: Input,
        bookmarks: [BookmarkRecord],
        notes: [MeetingNoteRecord],
        screenshots: [MeetingScreenshotRecord]
    ) -> MeetingTimelineProjectionSnapshot? {
        let previous = cached.input
        guard input.bookmarks == previous.bookmarks,
              input.notes == previous.notes,
              input.screenshots == previous.screenshots,
              input.customSpeakerNames == previous.customSpeakerNames,
              input.preservingDraftTargets
                == previous.preservingDraftTargets,
              input.transcripts.count > previous.transcripts.count,
              input.transcripts.prefix(previous.transcripts.count)
                .elementsEqual(previous.transcripts),
              appendedEntriesAreChronological(
                  previous: previous.transcripts,
                  current: input.transcripts
              ),
              !cached.snapshot.visibleTurns.isEmpty else {
            return nil
        }

        let turns = TranscriptDisplayPolicy.appending(
            Array(input.transcripts.dropFirst(previous.transcripts.count)),
            to: cached.snapshot.visibleTurns,
            bookmarks: bookmarks,
            preservingDraftTargets: input.preservingDraftTargets
        )
        return makeSnapshot(
            turns: turns,
            notes: notes,
            screenshots: screenshots,
            customSpeakerNames: input.customSpeakerNames
        )
    }

    private func appendedEntriesAreChronological(
        previous: [CanonicalTranscriptEntry],
        current: [CanonicalTranscriptEntry]
    ) -> Bool {
        guard let previousLast = previous.last else { return false }
        var prior = previousLast
        for entry in current.dropFirst(previous.count) {
            // Equal starts can have a different persisted sequence order and
            // display end-time order. Rebuild to place those entries safely.
            guard entry.startTime > prior.startTime else { return false }
            prior = entry
        }
        return true
    }

    private func makeSnapshot(
        turns: [TranscriptDisplayTurn],
        notes: [MeetingNoteRecord],
        screenshots: [MeetingScreenshotRecord],
        customSpeakerNames: [String: String]
    ) -> MeetingTimelineProjectionSnapshot {
        MeetingTimelineProjectionSnapshot(
            visibleTurns: turns,
            timelineItems: MeetingTimelineDisplayPolicy.items(
                transcriptTurns: turns,
                notes: notes,
                screenshots: screenshots
            ),
            speakerOptions: speakerOptions(
                turns: turns,
                customSpeakerNames: customSpeakerNames
            )
        )
    }

    private func speakerOptions(
        turns: [TranscriptDisplayTurn],
        customSpeakerNames: [String: String]
    ) -> [TranscriptSpeakerOption] {
        var seen: Set<String> = []
        return turns.compactMap { turn in
            guard let speakerID = turn.speakerID,
                  seen.insert(speakerID).inserted,
                  let badge = TranscriptSpeakerDisplayPolicy.badge(
                      speakerID: speakerID,
                      source: turn.source,
                      customNames: customSpeakerNames
                  ) else {
                return nil
            }
            return TranscriptSpeakerOption(
                speakerID: speakerID,
                badge: badge
            )
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
