import Foundation

/// Completes legacy/coarse results without discarding confidence metadata, text,
/// timestamps, corrections or manual identities. No model or network work here.
enum AutomaticSpeakerAttribution {
    struct Span {
        let start: Double
        let end: Double
        let source: TranscriptAudioSource
        let speakerID: String?
        let candidateID: String?
        let mayPropagate: Bool
    }

    static func defaultID(for source: TranscriptAudioSource) -> String {
        switch source {
        case .microphone: "me"
        case .system: "remote-1"
        case .room: "room-1"
        case .mixed: "speaker-1"
        }
    }

    private static func ids(for spans: [Span]) -> [String] {
        let grouped = Dictionary(grouping: spans, by: \.source)
        let indexes = grouped.mapValues { group in
            SpeakerEvidenceIndex(group.compactMap { span in
                guard span.mayPropagate, let id = span.speakerID ?? span.candidateID else { return nil }
                return SpeakerInterval(rawSpeakerID: id, startTime: span.start, endTime: span.end)
            })
        }
        return spans.map { span in
            span.speakerID ?? span.candidateID ?? indexes[span.source]?
                .bestEffortSpeaker(start: span.start, end: span.end) ?? defaultID(for: span.source)
        }
    }

    static func complete(_ entries: [CanonicalTranscriptEntry]) -> [CanonicalTranscriptEntry] {
        guard entries.contains(where: { $0.speakerID == nil }) else { return entries }
        let assigned = ids(for: entries.map {
            Span(start: $0.startTime, end: $0.endTime, source: $0.source,
                 speakerID: $0.speakerID, candidateID: $0.reviewHint?.candidateSpeakerID,
                 mayPropagate: $0.attributionStatus != .manuallyAssigned)
        })
        return zip(entries, assigned).map { entry, id in
            CanonicalTranscriptEntry(id: entry.id, transcriptIDs: entry.transcriptIDs,
                startTime: entry.startTime, endTime: entry.endTime, text: entry.text,
                speakerID: id, source: entry.source, isManuallyEdited: entry.isManuallyEdited,
                attributionStatus: entry.speakerID == nil && entry.attributionStatus != .overlapping
                    ? .inferred : entry.attributionStatus,
                sourceEvidence: entry.sourceEvidence, reviewHint: entry.reviewHint)
        }
    }

    static func complete(_ drafts: [AttributedTranscriptDraft]) -> [AttributedTranscriptDraft] {
        guard drafts.contains(where: { $0.speakerID == nil }) else { return drafts }
        let assigned = ids(for: drafts.map {
            Span(start: $0.transcript.startTime, end: $0.transcript.endTime, source: $0.source,
                 speakerID: $0.speakerID, candidateID: $0.reviewHint?.candidateSpeakerID,
                 mayPropagate: $0.attributionStatus != .manuallyAssigned)
        })
        return zip(drafts, assigned).map { draft, id in
            AttributedTranscriptDraft(transcript: draft.transcript, speakerID: id, source: draft.source,
                attributionStatus: draft.speakerID == nil && draft.attributionStatus != .overlapping
                    ? .inferred : draft.attributionStatus,
                sourceEvidence: draft.sourceEvidence, attributionOrigin: draft.attributionOrigin,
                automaticSpeakerID: draft.automaticSpeakerID,
                automaticAttributionStatus: draft.automaticAttributionStatus, reviewHint: draft.reviewHint)
        }
    }
}
