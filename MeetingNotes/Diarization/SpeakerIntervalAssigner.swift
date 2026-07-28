import Foundation

struct SpeakerIntervalAssigner: Sendable {
    func assign(
        _ drafts: [TranscriptDraft],
        intervals: [SpeakerInterval],
        speakerPrefix: String,
        source: TranscriptAudioSource
    ) -> [AttributedTranscriptDraft] {
        let rawSpeakerIDs = assignedRawSpeakerIDs(
            drafts,
            intervals: intervals
        )
        let chronologicalIndices = drafts.indices.sorted { lhs, rhs in
            let left = drafts[lhs]
            let right = drafts[rhs]
            if left.startTime != right.startTime {
                return left.startTime < right.startTime
            }
            if left.endTime != right.endTime {
                return left.endTime < right.endTime
            }
            return lhs < rhs
        }

        var stableIDs: [String: String] = [:]
        for index in chronologicalIndices {
            guard let rawSpeakerID = rawSpeakerIDs[index],
                  stableIDs[rawSpeakerID] == nil else {
                continue
            }
            stableIDs[rawSpeakerID] =
                "\(speakerPrefix)-\(stableIDs.count + 1)"
        }

        return drafts.indices.map { index in
            AttributedTranscriptDraft(
                transcript: drafts[index],
                speakerID: rawSpeakerIDs[index].flatMap {
                    stableIDs[$0]
                },
                source: source
            )
        }
    }

    func assignedRawSpeakerIDs(
        _ drafts: [TranscriptDraft],
        intervals: [SpeakerInterval]
    ) -> [String?] {
        let validIntervals: [SpeakerInterval] = intervals.compactMap {
            interval in
            let rawSpeakerID = interval.rawSpeakerID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawSpeakerID.isEmpty,
                  interval.startTime.isFinite,
                  interval.endTime.isFinite,
                  interval.startTime >= 0,
                  interval.endTime > interval.startTime else {
                return nil
            }
            return SpeakerInterval(
                rawSpeakerID: rawSpeakerID,
                startTime: interval.startTime,
                endTime: interval.endTime
            )
        }
        return drafts.map { draft in
            bestInterval(for: draft, intervals: validIntervals)?
                .rawSpeakerID
        }
    }

    private func bestInterval(
        for draft: TranscriptDraft,
        intervals: [SpeakerInterval]
    ) -> SpeakerInterval? {
        intervals.min { lhs, rhs in
            let leftOverlap = overlap(draft, lhs)
            let rightOverlap = overlap(draft, rhs)
            if leftOverlap != rightOverlap {
                return leftOverlap > rightOverlap
            }

            if leftOverlap == 0 {
                let leftDistance = distance(draft, lhs)
                let rightDistance = distance(draft, rhs)
                if leftDistance != rightDistance {
                    return leftDistance < rightDistance
                }
            }

            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.endTime != rhs.endTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.rawSpeakerID < rhs.rawSpeakerID
        }
    }

    private func overlap(
        _ draft: TranscriptDraft,
        _ interval: SpeakerInterval
    ) -> TimeInterval {
        max(
            0,
            min(draft.endTime, interval.endTime)
                - max(draft.startTime, interval.startTime)
        )
    }

    private func distance(
        _ draft: TranscriptDraft,
        _ interval: SpeakerInterval
    ) -> TimeInterval {
        if interval.endTime <= draft.startTime {
            return draft.startTime - interval.endTime
        }
        if draft.endTime <= interval.startTime {
            return interval.startTime - draft.endTime
        }
        return 0
    }
}
