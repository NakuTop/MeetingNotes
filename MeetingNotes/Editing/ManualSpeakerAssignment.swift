import Foundation

enum SpeakerAssignmentError: Error, Equatable {
    case staleTranscript
    case invalidSpeaker
}

// Stable numeric identities and human decisions are distinct from a model's
// fresh cluster numbering. Only used when there are protected manual rows.
@MainActor
enum ManualSpeakerAssignment {
    static func nextSpeakerID(records: [TranscriptRecord], mode: MeetingMode, reservedIDs: Set<String> = []) -> String {
        let prefix = mode == .offline ? "room" : "speaker"
        let ids = Set(records.compactMap(\.speakerID)).union(reservedIDs)
            .union(records.compactMap { $0.reviewHint?.candidateSpeakerID })
        let numbers = ids.compactMap { $0.split(separator: "-").last }.compactMap { Int($0) }
        let maximum = max(0, numbers.max() ?? 0)
        var next = maximum < Int.max ? maximum + 1 : 1
        while ids.contains("\(prefix)-\(next)") { next += 1 }
        return "\(prefix)-\(next)"
    }

    static func stabilize(_ drafts: [AttributedTranscriptDraft], against records: [TranscriptRecord])
        -> [AttributedTranscriptDraft] {
        guard records.contains(where: { $0.attributionStatus == .manuallyAssigned }) else { return drafts }
        let groups = Dictionary(grouping: records.filter { $0.speakerID != nil }, by: { $0.speakerID! })
        let evidence = groups.map { id, rows in
            SpeakerNameEvidence(speakerID: id, displayName: id, intervals: rows.map {
                SpeakerNameEvidenceInterval(startTime: $0.startTime, endTime: $0.endTime, source: $0.source)
            })
        }
        var mapping = SpeakerNameRemapper().remap(oldNamedSpeakers: evidence, newDrafts: drafts)
        let reserved = Set(groups.keys)
        var allocated = reserved.union(mapping.values)
        let allIDs = Set(drafts.compactMap(\.speakerID))
            .union(drafts.compactMap { $0.reviewHint?.candidateSpeakerID })
            .union(drafts.compactMap { $0.reviewHint?.alternativeSpeakerID })
        for id in allIDs.sorted() where mapping[id] == nil {
            let parsed = id.split(separator: "-").dropLast().joined(separator: "-")
            let prefix = parsed.isEmpty ? "speaker" : parsed
            var number = 1
            while allocated.contains("\(prefix)-\(number)") { number += 1 }
            let replacement = "\(prefix)-\(number)"
            mapping[id] = replacement
            allocated.insert(replacement)
        }
        return drafts.map {
            AttributedTranscriptDraft(transcript: $0.transcript,
                speakerID: $0.speakerID.flatMap { mapping[$0] }, source: $0.source,
                attributionStatus: $0.attributionStatus, sourceEvidence: $0.sourceEvidence,
                attributionOrigin: $0.attributionOrigin,
                automaticSpeakerID: $0.automaticSpeakerID.flatMap { mapping[$0] },
                automaticAttributionStatus: $0.automaticAttributionStatus,
                reviewHint: $0.reviewHint?.remapping(mapping))
        }
    }
}
