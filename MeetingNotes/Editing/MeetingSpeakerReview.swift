import Foundation

struct SpeakerReviewRowSnapshot: Equatable, Sendable {
    let id: UUID
    let start: Double
    let end: Double
    let source: TranscriptAudioSource
    let hint: SpeakerReviewHint

    @MainActor
    func matches(_ row: TranscriptRecord) -> Bool {
        row.id == id && row.isFinal && row.startTime == start && row.endTime == end && row.source == source &&
            row.speakerID == nil && row.attributionStatus == .uncertain && row.reviewHint == hint
    }
}

struct SpeakerReviewItem: Identifiable, Sendable {
    let id: UUID
    let text: String
    let rows: [SpeakerReviewRowSnapshot]
    var start: Double { rows.map(\.start).min() ?? 0 }
    var end: Double { rows.map(\.end).max() ?? start }
    var reason: String { rows.first?.hint.reason.label ?? "需要试听" }
}

struct SpeakerReviewGroup: Identifiable, Sendable {
    let id: String
    let items: [SpeakerReviewItem]
}

struct MeetingSpeakerReviewCatalog: Sendable {
    let groups: [SpeakerReviewGroup]
    let ungroupedCount: Int
    let totalUncertainCount: Int
    let speakerIDs: [String]

    @MainActor
    static func make(meeting: MeetingRecord) -> Self {
        let rowsByID = Dictionary(uniqueKeysWithValues: meeting.transcripts.map { ($0.id, $0) })
        let entries = TranscriptCorrectionResolver.resolve(transcripts: meeting.transcripts, corrections: meeting.transcriptCorrections)
        var items: [String: [SpeakerReviewItem]] = [:]
        var ungrouped = 0
        var total = 0
        for entry in entries where entry.attributionStatus == .uncertain || entry.attributionStatus == .overlapping {
            total += 1
            guard entry.attributionStatus == .uncertain, let hint = entry.reviewHint, hint.canGroupForReview,
                  let candidate = hint.candidateSpeakerID else { ungrouped += 1; continue }
            let rows = entry.transcriptIDs.compactMap { rowsByID[$0] }
            guard !rows.isEmpty, rows.count == entry.transcriptIDs.count, rows.allSatisfy({
                $0.isFinal && $0.speakerID == nil && $0.attributionStatus == .uncertain &&
                    $0.reviewHint?.canGroupForReview == true && $0.reviewHint?.candidateSpeakerID == candidate
            }) else { ungrouped += 1; continue }
            items[candidate, default: []].append(.init(id: entry.id, text: entry.text, rows: rows.map {
                .init(id: $0.id, start: $0.startTime, end: $0.endTime, source: $0.source, hint: $0.reviewHint!)
            }))
        }
        let groups = items.map { SpeakerReviewGroup(id: $0.key, items: $0.value.sorted { $0.start < $1.start }) }
            .sorted { ($0.items.first?.start ?? 0) < ($1.items.first?.start ?? 0) }
        let ids = Set(meeting.transcripts.compactMap(\.speakerID)).union(groups.map(\.id))
        return .init(groups: groups, ungroupedCount: ungrouped, totalUncertainCount: total,
                     speakerIDs: ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

struct SpeakerAssignmentSnapshot: Equatable, Sendable {
    let id: UUID
    let speakerID: String?
    let status: String?
    let automaticSpeakerID: String?
    let automaticStatus: String?

    @MainActor init(_ row: TranscriptRecord) {
        id = row.id; speakerID = row.speakerID; status = row.attributionStatusRawValue
        automaticSpeakerID = row.automaticSpeakerID; automaticStatus = row.automaticSpeakerStatusRawValue
    }

    @MainActor func restore(_ row: TranscriptRecord) {
        row.speakerID = speakerID; row.attributionStatusRawValue = status
        row.automaticSpeakerID = automaticSpeakerID; row.automaticSpeakerStatusRawValue = automaticStatus
    }
}

struct SpeakerBatchAssignmentReceipt: Sendable {
    let id: UUID
    let meetingID: UUID
    let speakerID: String
    let before: [SpeakerAssignmentSnapshot]
    let after: [SpeakerAssignmentSnapshot]
}
