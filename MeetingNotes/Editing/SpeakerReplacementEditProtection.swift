import Foundation

@MainActor
enum SpeakerReplacementEditProtection {
    static func preserveEditedRows(
        in drafts: [AttributedTranscriptDraft],
        originals: [TranscriptRecord],
        corrections: [TranscriptCorrectionRecord]
    ) throws -> [AttributedTranscriptDraft] {
        let manuallyAssigned = originals.filter { $0.attributionStatus == .manuallyAssigned }
        let protectedIDs = Set(
            TranscriptCorrectionResolver.resolve(transcripts: originals, corrections: corrections)
                .filter(\.isManuallyEdited).flatMap(\.transcriptIDs)).union(manuallyAssigned.map(\.id))
        guard !protectedIDs.isEmpty else { return drafts }
        let protected = Dictionary(grouping: originals.filter { protectedIDs.contains($0.id) }) {
            TranscriptAttributionOrigin(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
        }
        let groups = Dictionary(grouping: drafts.filter { $0.attributionOrigin != nil }) {
            $0.attributionOrigin!
        }
        // Do not silently discard a correction when an unexpected replacement
        // cannot be traced back to the rows the user actually labelled.
        for row in manuallyAssigned {
            let origin = TranscriptAttributionOrigin(startTime: row.startTime, endTime: row.endTime, text: row.text)
            guard protected[origin]?.count == 1, groups[origin] != nil else {
                throw SpeakerAssignmentError.staleTranscript
            }
        }
        var emitted: Set<TranscriptAttributionOrigin> = []
        return drafts.compactMap { draft in
            guard let origin = draft.attributionOrigin,
                let matching = protected[origin], matching.count == 1,
                let original = matching.first, let group = groups[origin]
            else { return draft }
            guard emitted.insert(origin).inserted else { return nil }
            let speakers = Set(group.map(\.speakerID))
            let dominant = SpeakerEvidenceIndex(group.compactMap { piece in
                piece.speakerID.map { SpeakerInterval(rawSpeakerID: $0,
                    startTime: piece.transcript.startTime, endTime: piece.transcript.endTime) }
            }).bestEffortSpeaker(start: original.startTime, end: original.endTime)
            let status: SpeakerAttributionStatus? =
                group.contains { $0.attributionStatus == .overlapping }
                ? .overlapping : (speakers.count == 1 ? group.first?.attributionStatus : .inferred)
            // An edited sentence may span several voices. Keep its anchor and
            // exact user correction intact; do not invent word alignment for
            // text typed by the user or show duplicate uncorrected child rows.
            let manual = original.attributionStatus == .manuallyAssigned
            return AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: original.startTime, endTime: original.endTime,
                    text: original.text, words: original.words),
                speakerID: manual ? original.speakerID : dominant,
                source: manual ? original.source : draft.source,
                attributionStatus: manual ? .manuallyAssigned : status,
                sourceEvidence: Set(group.map(\.sourceEvidence)).count == 1
                    ? group.first?.sourceEvidence : .mixed,
                attributionOrigin: origin,
                automaticSpeakerID: manual ? dominant : nil,
                automaticAttributionStatus: manual ? status : nil,
                reviewHint: SpeakerReviewHint.consensus(group.map(\.reviewHint))
            )
        }
    }
}
