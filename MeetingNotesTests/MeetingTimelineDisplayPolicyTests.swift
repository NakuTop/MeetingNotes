import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingTimelineDisplayPolicyTests: XCTestCase {
    func testEmptyManualCorrectionKeepsEditableRowButEmptyGeneratedTextStaysHidden() {
        let manualID = UUID()
        let generatedID = UUID()
        let entries = [
            CanonicalTranscriptEntry(
                id: manualID, transcriptIDs: [UUID()], startTime: 0, endTime: 3,
                text: "", speakerID: nil, source: .microphone, isManuallyEdited: true
            ),
            CanonicalTranscriptEntry(
                id: generatedID, transcriptIDs: [generatedID], startTime: 4, endTime: 5,
                text: " \n ", speakerID: nil, source: .microphone, isManuallyEdited: false
            ),
        ]

        let visible = TranscriptDisplayPolicy.entries(from: entries)

        XCTAssertEqual(visible.map(\.id), [manualID])
        XCTAssertEqual(visible.first?.text, "")
        XCTAssertEqual(visible.first?.correctionID, manualID)
    }

    func testProjectionCacheReusesIdenticalStructuralVersion() {
        let cache = MeetingTimelineProjectionCache()
        let entries = projectionEntries(count: 3)
        let version = MeetingTimelineProjectionVersion(
            contentRevision: 1,
            draftBoundaryRevision: 0
        )

        let first = cache.snapshot(
            version: version,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )
        let second = cache.snapshot(
            version: version,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.fullRebuildCount, 1)
        XCTAssertEqual(cache.incrementalAppendCount, 0)
        XCTAssertEqual(cache.cacheHitCount, 1)
    }

    func testDraftBoundaryInvalidatesProjectionButCharacterOnlyVersionDoesNot() {
        let cache = MeetingTimelineProjectionCache()
        let entries = projectionEntries(count: 3)
        let clean = MeetingTimelineProjectionVersion(
            contentRevision: 1,
            draftBoundaryRevision: 0
        )
        let dirty = MeetingTimelineProjectionVersion(
            contentRevision: 1,
            draftBoundaryRevision: 1
        )
        let target = MeetingTranscriptEditTarget(entry: entries[1])

        _ = cache.snapshot(
            version: clean,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )
        _ = cache.snapshot(
            version: dirty,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: [],
            preservingDraftTargets: [target]
        )
        _ = cache.snapshot(
            version: dirty,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: [],
            preservingDraftTargets: [target]
        )

        XCTAssertEqual(cache.fullRebuildCount, 2)
        XCTAssertEqual(cache.cacheHitCount, 1)
    }

    func testChangedDraftScopeCannotReuseSnapshotEvenWithSameVersion() {
        let cache = MeetingTimelineProjectionCache()
        let entries = projectionEntries(count: 3)
        let version = MeetingTimelineProjectionVersion(
            contentRevision: 1,
            draftBoundaryRevision: 1
        )
        let firstTarget = MeetingTranscriptEditTarget(entry: entries[0])
        let changedScope = MeetingTranscriptEditTarget(
            canonicalEntryID: firstTarget.canonicalEntryID,
            correctionID: firstTarget.correctionID,
            transcriptIDs: firstTarget.transcriptIDs + entries[1].transcriptIDs,
            anchorStartTime: firstTarget.anchorStartTime,
            anchorEndTime: entries[1].endTime,
            source: firstTarget.source,
            originalText: firstTarget.originalText
        )

        _ = cache.snapshot(
            version: version,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: [],
            preservingDraftTargets: [firstTarget]
        )
        _ = cache.snapshot(
            version: version,
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: [],
            preservingDraftTargets: [changedScope]
        )

        XCTAssertEqual(cache.fullRebuildCount, 2)
        XCTAssertEqual(cache.cacheHitCount, 0)
    }

    func testSafeTranscriptAppendUsesIncrementalProjectionEqualToFullBuild() {
        let initialEntries = projectionEntries(count: 2)
        let appendedEntries = projectionEntries(count: 4)
        let cache = MeetingTimelineProjectionCache()

        _ = cache.snapshot(
            version: MeetingTimelineProjectionVersion(
                contentRevision: 1,
                draftBoundaryRevision: 0
            ),
            transcripts: initialEntries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )
        let incremental = cache.snapshot(
            version: MeetingTimelineProjectionVersion(
                contentRevision: 2,
                draftBoundaryRevision: 0
            ),
            transcripts: appendedEntries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )
        let full = MeetingTimelineProjectionCache().snapshot(
            version: MeetingTimelineProjectionVersion(
                contentRevision: 2,
                draftBoundaryRevision: 0
            ),
            transcripts: appendedEntries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )

        XCTAssertEqual(incremental, full)
        XCTAssertEqual(cache.fullRebuildCount, 1)
        XCTAssertEqual(cache.incrementalAppendCount, 1)
    }

    func testOutOfOrderAppendFallsBackToFullProjection() {
        let first = projectionEntry(index: 1, startTime: 10)
        let outOfOrder = projectionEntry(index: 2, startTime: 5)
        let cache = MeetingTimelineProjectionCache()

        _ = cache.snapshot(
            version: MeetingTimelineProjectionVersion(
                contentRevision: 1,
                draftBoundaryRevision: 0
            ),
            transcripts: [first],
            bookmarks: [],
            notes: [],
            screenshots: []
        )
        let result = cache.snapshot(
            version: MeetingTimelineProjectionVersion(
                contentRevision: 2,
                draftBoundaryRevision: 0
            ),
            transcripts: [first, outOfOrder],
            bookmarks: [],
            notes: [],
            screenshots: []
        )

        XCTAssertEqual(cache.fullRebuildCount, 2)
        XCTAssertEqual(cache.incrementalAppendCount, 0)
        XCTAssertEqual(result.visibleTurns.map(\.startTime), [5, 10])
    }

    func testSameStartAppendFallsBackWhenDisplayOrderDiffersFromStoredOrder() {
        let entries = [10.0, 1.0, 2.0].enumerated().map { index, end in
            let id = deterministicUUID(index + 40_000)
            return CanonicalTranscriptEntry(
                id: id,
                transcriptIDs: [id],
                startTime: 0,
                endTime: end,
                text: "同时开始的第\(index)段",
                speakerID: "room-\(index + 1)",
                source: .room,
                isManuallyEdited: false
            )
        }
        let cache = MeetingTimelineProjectionCache()
        _ = projection(cache: cache, entries: Array(entries.prefix(2)), revision: 1)

        let appended = projection(cache: cache, entries: entries, revision: 2)
        let full = projection(
            cache: MeetingTimelineProjectionCache(),
            entries: entries,
            revision: 2
        )

        XCTAssertEqual(appended, full)
        XCTAssertEqual(appended.visibleTurns.map(\.canonicalEntryID),
                       [entries[1].id, entries[2].id, entries[0].id])
        XCTAssertEqual(cache.fullRebuildCount, 2)
        XCTAssertEqual(cache.incrementalAppendCount, 0)
    }

    func testFourHourThreeThousandSegmentFixturePreservesOrderAndScale() {
        let segmentCount = 3_000
        let meetingDuration: TimeInterval = 4 * 60 * 60
        let segmentDuration = meetingDuration / Double(segmentCount)
        let entries = (0..<segmentCount).map { index in
            let start = Double(index) * segmentDuration
            return CanonicalTranscriptEntry(
                id: deterministicUUID(index),
                transcriptIDs: [deterministicUUID(index)],
                startTime: start,
                endTime: start + segmentDuration,
                text: "第\(index + 1)段转录",
                speakerID: "room-\((index % 2) + 1)",
                source: .room,
                isManuallyEdited: false
            )
        }

        let turns = TranscriptDisplayPolicy.turns(
            from: entries,
            bookmarks: []
        )
        let items = MeetingTimelineDisplayPolicy.items(
            transcriptTurns: turns,
            notes: [
                MeetingNoteRecord(
                    id: deterministicUUID(segmentCount),
                    timestamp: meetingDuration / 2,
                    text: "中途笔记",
                    sequenceIndex: 0
                ),
            ],
            screenshots: [
                MeetingScreenshotRecord(
                    id: deterministicUUID(segmentCount + 1),
                    timestamp: meetingDuration - 1,
                    relativePath: "meeting/screenshots/final.png",
                    pixelWidth: 1_280,
                    pixelHeight: 720,
                    byteCount: 100,
                    sequenceIndex: 0
                ),
            ]
        )

        XCTAssertEqual(turns.count, segmentCount)
        XCTAssertEqual(items.count, segmentCount + 2)
        XCTAssertEqual(turns.first?.startTime, 0)
        XCTAssertEqual(
            turns.last?.endTime ?? 0,
            meetingDuration,
            accuracy: 0.001
        )
        XCTAssertTrue(
            zip(items, items.dropFirst()).allSatisfy {
                $0.timestamp <= $1.timestamp
            }
        )
    }

    func testThreeThousandConsecutiveSameSpeakerSegmentsPreserveEntireTurn() {
        let entries = continuousSpeakerEntries(count: 3_000)
        var turns: [TranscriptDisplayTurn] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: options) {
            turns = TranscriptDisplayPolicy.turns(
                from: entries,
                bookmarks: []
            )
        }

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.canonicalEntryID, entries.first?.id)
        XCTAssertEqual(turns.first?.transcriptIDs, entries.map(\.id))
        XCTAssertEqual(turns.first?.text, entries.map(\.text).joined(separator: " "))
        XCTAssertEqual(turns.first?.startTime, 0)
        XCTAssertEqual(turns.first?.endTime, 14_400)
        XCTAssertEqual(turns.first?.speakerID, "room-1")
        XCTAssertEqual(turns.first?.source, .room)
        XCTAssertEqual(turns.first?.isHighlighted, false)
    }

    func testLongSameSpeakerAppendMatchesFullProjection() {
        let entries = continuousSpeakerEntries(count: 3_001)
        let cache = MeetingTimelineProjectionCache()
        _ = projection(cache: cache, entries: Array(entries.dropLast()), revision: 1)

        let appended = projection(cache: cache, entries: entries, revision: 2)
        let full = projection(
            cache: MeetingTimelineProjectionCache(),
            entries: entries,
            revision: 2
        )

        XCTAssertEqual(appended, full)
        XCTAssertEqual(appended.visibleTurns.count, 1)
        XCTAssertEqual(appended.visibleTurns.first?.transcriptIDs, entries.map(\.id))
        XCTAssertEqual(cache.incrementalAppendCount, 1)
        XCTAssertEqual(cache.fullRebuildCount, 1)
    }

    func testLongSameSpeakerDraftScopePreservesBothEditingBoundaries() throws {
        let entries = continuousSpeakerEntries(count: 3_000)
        let editedEntries = Array(entries[1_000..<2_000])
        let target = MeetingTranscriptEditTarget(
            canonicalEntryID: editedEntries[0].id,
            correctionID: nil,
            transcriptIDs: editedEntries.map(\.id),
            anchorStartTime: editedEntries[0].startTime,
            anchorEndTime: try XCTUnwrap(editedEntries.last).endTime,
            source: .room,
            originalText: editedEntries.map(\.text).joined(separator: " ")
        )

        let turns = TranscriptDisplayPolicy.turns(
            from: entries,
            bookmarks: [],
            preservingDraftTargets: [target]
        )

        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map { $0.transcriptIDs.count }, [1_000, 1_000, 1_000])
        XCTAssertEqual(turns.flatMap(\.transcriptIDs), entries.map(\.id))
        XCTAssertEqual(turns[1].transcriptIDs, target.transcriptIDs)
        XCTAssertEqual(turns[1].text, target.originalText)
        XCTAssertEqual(turns.map(\.text).joined(separator: " "),
                       entries.map(\.text).joined(separator: " "))
    }

    func testAppendRespectsExistingDraftAndAllGroupingBoundaries() {
        let entries = continuousSpeakerEntries(count: 12)
        let target = MeetingTranscriptEditTarget(entry: entries[8])
        let bookmarks = [BookmarkRecord(timestamp: entries[10].startTime)]
        let cache = MeetingTimelineProjectionCache()
        _ = cache.snapshot(
            version: .init(contentRevision: 1, draftBoundaryRevision: 1),
            transcripts: Array(entries.prefix(9)),
            bookmarks: bookmarks,
            notes: [],
            screenshots: [],
            preservingDraftTargets: [target]
        )
        let appended = cache.snapshot(
            version: .init(contentRevision: 2, draftBoundaryRevision: 1),
            transcripts: entries,
            bookmarks: bookmarks,
            notes: [],
            screenshots: [],
            preservingDraftTargets: [target]
        )
        let full = MeetingTimelineProjectionCache().snapshot(
            version: .init(contentRevision: 2, draftBoundaryRevision: 1),
            transcripts: entries,
            bookmarks: bookmarks,
            notes: [],
            screenshots: [],
            preservingDraftTargets: [target]
        )

        XCTAssertEqual(appended, full)
        XCTAssertEqual(cache.incrementalAppendCount, 1)
        XCTAssertTrue(appended.visibleTurns.contains {
            $0.transcriptIDs == target.transcriptIDs
        })
    }

    func testIncrementalAppendMatchesFullAcrossSourceSpeakerCorrectionAndGapChanges() {
        func entry(
            _ index: Int,
            start: TimeInterval? = nil,
            text: String = "有效内容",
            speaker: String? = "room-1",
            source: TranscriptAudioSource = .room,
            corrected: Bool = false
        ) -> CanonicalTranscriptEntry {
            let id = deterministicUUID(index + 30_000)
            let startTime = start ?? Double(index)
            return CanonicalTranscriptEntry(
                id: id,
                transcriptIDs: [id],
                startTime: startTime,
                endTime: startTime + 1,
                text: text,
                speakerID: speaker,
                source: source,
                isManuallyEdited: corrected
            )
        }
        let entries = [
            entry(0),
            entry(1),
            entry(2, corrected: true),
            entry(3, text: " \n "),
            entry(4),
            entry(5, source: .microphone),
            entry(6, speaker: nil, source: .microphone),
            entry(7, speaker: nil, source: .microphone),
            entry(8, start: 20, source: .microphone),
            entry(9, start: 30, source: .microphone),
            entry(10, start: 31, source: .microphone),
        ]
        let cache = MeetingTimelineProjectionCache()
        var latest: MeetingTimelineProjectionSnapshot = .empty

        for count in 1...entries.count {
            let prefix = Array(entries.prefix(count))
            latest = projection(cache: cache, entries: prefix, revision: count)
            let full = projection(
                cache: MeetingTimelineProjectionCache(),
                entries: prefix,
                revision: count
            )
            XCTAssertEqual(latest, full, "Append boundary at entry \(count)")
        }

        XCTAssertEqual(latest.visibleTurns.count, 8)
        XCTAssertEqual(latest.visibleTurns.first?.transcriptIDs,
                       Array(entries.prefix(2)).map(\.id))
        XCTAssertEqual(latest.visibleTurns.last?.transcriptIDs,
                       Array(entries.suffix(2)).map(\.id))
        XCTAssertEqual(cache.incrementalAppendCount, entries.count - 1)
    }

    func testMixedEventsSortByTimestampThenSequenceAndStableIdentity() {
        let transcriptID = fixedUUID("00000000-0000-0000-0000-000000000003")
        let earlierScreenshotID = fixedUUID(
            "00000000-0000-0000-0000-000000000001"
        )
        let laterScreenshotID = fixedUUID(
            "00000000-0000-0000-0000-000000000004"
        )
        let sameSequenceEarlierID = fixedUUID(
            "00000000-0000-0000-0000-000000000000"
        )
        let noteID = fixedUUID("00000000-0000-0000-0000-000000000002")
        let turn = TranscriptDisplayTurn(
            canonicalEntryID: transcriptID,
            correctionID: nil,
            transcriptIDs: [transcriptID],
            startTime: 3,
            endTime: 4,
            text: "转录",
            speakerID: "room-1",
            source: .room,
            isHighlighted: false
        )
        let notes = [
            MeetingNoteRecord(
                id: noteID,
                timestamp: 3,
                text: "笔记",
                sequenceIndex: 1
            ),
        ]
        let screenshots = [
            MeetingScreenshotRecord(
                id: laterScreenshotID,
                timestamp: 3,
                relativePath: "meeting/screenshots/later.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 2
            ),
            MeetingScreenshotRecord(
                id: earlierScreenshotID,
                timestamp: 1,
                relativePath: "meeting/screenshots/earlier.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 0
            ),
            MeetingScreenshotRecord(
                id: sameSequenceEarlierID,
                timestamp: 3,
                relativePath: "meeting/screenshots/same-sequence.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 2
            ),
        ]

        let items = MeetingTimelineDisplayPolicy.items(
            transcriptTurns: [turn],
            notes: notes,
            screenshots: screenshots
        )

        XCTAssertEqual(
            items.map(\.id),
            [
                earlierScreenshotID,
                transcriptID,
                noteID,
                sameSequenceEarlierID,
                laterScreenshotID,
            ]
        )
        XCTAssertEqual(items.map(\.timestamp), [1, 3, 3, 3, 3])
    }

    func testNoteOnlyMeetingProducesVisibleTimelineItem() {
        let noteID = UUID()
        let items = MeetingTimelineDisplayPolicy.items(
            transcriptTurns: [],
            notes: [
                MeetingNoteRecord(
                    id: noteID,
                    timestamp: 7.5,
                    text: "只有笔记也要显示",
                    sequenceIndex: 0
                ),
            ],
            screenshots: []
        )

        XCTAssertEqual(items.count, 1)
        guard case let .note(note) = items[0] else {
            return XCTFail("Expected a note timeline item")
        }
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(note.timestamp, 7.5)
        XCTAssertEqual(note.text, "只有笔记也要显示")
    }

    private func fixedUUID(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func deterministicUUID(_ index: Int) -> UUID {
        fixedUUID(
            String(
                format: "00000000-0000-0000-0000-%012llx",
                Int64(index + 1)
            )
        )
    }

    private func projectionEntries(
        count: Int
    ) -> [CanonicalTranscriptEntry] {
        (0..<count).map {
            projectionEntry(index: $0, startTime: Double($0) * 2)
        }
    }

    private func continuousSpeakerEntries(count: Int) -> [CanonicalTranscriptEntry] {
        (0..<count).map { index in
            let id = deterministicUUID(index + 20_000)
            return CanonicalTranscriptEntry(
                id: id,
                transcriptIDs: [id],
                startTime: Double(index) * 4.8,
                endTime: Double(index + 1) * 4.8,
                text: "第\(index + 1)段连续发言，讨论项目的进展和接下来的工作安排。",
                speakerID: "room-1",
                source: .room,
                isManuallyEdited: false
            )
        }
    }

    private func projection(
        cache: MeetingTimelineProjectionCache,
        entries: [CanonicalTranscriptEntry],
        revision: Int
    ) -> MeetingTimelineProjectionSnapshot {
        cache.snapshot(
            version: .init(contentRevision: revision, draftBoundaryRevision: 0),
            transcripts: entries,
            bookmarks: [],
            notes: [],
            screenshots: []
        )
    }

    private func projectionEntry(
        index: Int,
        startTime: TimeInterval
    ) -> CanonicalTranscriptEntry {
        let id = deterministicUUID(index + 10_000)
        return CanonicalTranscriptEntry(
            id: id,
            transcriptIDs: [id],
            startTime: startTime,
            endTime: startTime + 1,
            text: "第\(index)段",
            speakerID: "room-\((index % 2) + 1)",
            source: .room,
            isManuallyEdited: false
        )
    }
}
