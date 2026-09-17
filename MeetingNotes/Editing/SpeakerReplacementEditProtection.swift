import Foundation

@MainActor
enum SpeakerReplacementEditProtection {
    static func preserveEditedRows(
        in drafts: [AttributedTranscriptDraft],
        originals: [TranscriptRecord],
        corrections: [TranscriptCorrectionRecord]
    ) -> [AttributedTranscriptDraft] {
        let protectedIDs = Set(
            TranscriptCorrectionResolver.resolve(transcripts: originals, corrections: corrections)
                .filter(\.isManuallyEdited).flatMap(\.transcriptIDs))
        guard !protectedIDs.isEmpty else { return drafts }
        let protected = Dictionary(grouping: originals.filter { protectedIDs.contains($0.id) }) {
            TranscriptAttributionOrigin(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
        }
        let groups = Dictionary(grouping: drafts.filter { $0.attributionOrigin != nil }) {
            $0.attributionOrigin!
        }
        var emitted: Set<TranscriptAttributionOrigin> = []
        return drafts.compactMap { draft in
            guard let origin = draft.attributionOrigin,
                let matching = protected[origin], matching.count == 1,
                let original = matching.first, let group = groups[origin]
            else { return draft }
            guard emitted.insert(origin).inserted else { return nil }
            let speakers = Set(group.map(\.speakerID))
            let status: SpeakerAttributionStatus? =
                group.contains { $0.attributionStatus == .overlapping }
                ? .overlapping : (speakers.count == 1 ? group.first?.attributionStatus : .uncertain)
            // An edited sentence may span several voices. Keep its anchor and
            // exact user correction intact; do not invent word alignment for
            // text typed by the user or show duplicate uncorrected child rows.
            return AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: original.startTime, endTime: original.endTime,
                    text: original.text, words: original.words),
                speakerID: speakers.count == 1 ? group.first?.speakerID : nil,
                source: draft.source, attributionStatus: status,
                sourceEvidence: Set(group.map(\.sourceEvidence)).count == 1
                    ? group.first?.sourceEvidence : .mixed,
                attributionOrigin: origin
            )
        }
    }
}
