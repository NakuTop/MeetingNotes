import Foundation

struct SpeakerIntervalAssigner: Sendable {
    func assign(
        _ drafts: [TranscriptDraft],
        intervals: [SpeakerInterval],
        speakerPrefix: String,
        source: TranscriptAudioSource
    ) -> [AttributedTranscriptDraft] {
        let index = SpeakerEvidenceIndex(intervals)
        let pieces = drafts.flatMap { draft -> [(TranscriptDraft, SpeakerEvidence, TranscriptAttributionOrigin)] in
            let origin = TranscriptAttributionOrigin(startTime: draft.startTime, endTime: draft.endTime, text: draft.text)
            guard let units = TranscriptWordAlignment.units(in: draft) else {
                return [(draft, index.evidence(start: draft.startTime, end: draft.endTime), origin)]
            }
            var groups: [(Range<Int>, SpeakerEvidence)] = []
            for unitIndex in units.indices {
                let word = units[unitIndex].word
                let evidence = index.evidence(start: word.startTime, end: word.endTime)
                if let last = groups.last, last.1 == evidence {
                    groups[groups.count - 1].0 = last.0.lowerBound..<(unitIndex + 1)
                } else {
                    groups.append((unitIndex..<(unitIndex + 1), evidence))
                }
            }
            return groups.map { range, evidence in
                let first = units[range.lowerBound]
                let last = units[range.upperBound - 1]
                let text = String(draft.text[first.range.lowerBound..<last.range.upperBound])
                return (TranscriptDraft(
                    startTime: range.lowerBound == 0 ? draft.startTime : first.word.startTime,
                    endTime: range.upperBound == units.count ? draft.endTime : last.word.endTime,
                    text: text,
                    words: units[range].map(\.word)
                ), evidence, origin)
            }
        }
        // One mapping for the entire meeting, never a fresh number per chunk.
        let chronological = pieces.indices.sorted {
            if pieces[$0].0.startTime != pieces[$1].0.startTime {
                return pieces[$0].0.startTime < pieces[$1].0.startTime
            }
            return $0 < $1
        }
        var stableIDs: [String: String] = [:]
        for index in chronological {
            if let rawID = pieces[index].1.rawSpeakerID, stableIDs[rawID] == nil {
                stableIDs[rawID] = "\(speakerPrefix)-\(stableIDs.count + 1)"
            }
        }
        return pieces.map { draft, evidence, origin in
            AttributedTranscriptDraft(
                transcript: draft, speakerID: evidence.rawSpeakerID.flatMap { stableIDs[$0] }, source: source,
                attributionStatus: evidence.status, attributionOrigin: origin
            )
        }
    }

    func assignedRawSpeakerIDs(_ drafts: [TranscriptDraft], intervals: [SpeakerInterval]) -> [String?] {
        let index = SpeakerEvidenceIndex(intervals)
        return drafts.map { index.evidence(start: $0.startTime, end: $0.endTime).rawSpeakerID }
    }
}

private struct SpeakerEvidence: Equatable {
    let rawSpeakerID: String?
    let status: SpeakerAttributionStatus
    static let uncertain = Self(rawSpeakerID: nil, status: .uncertain)
}

private struct SpeakerEvidenceIndex {
    private let intervals: [SpeakerInterval]
    private let prefixEnds: [TimeInterval]

    init(_ input: [SpeakerInterval]) {
        intervals = input.compactMap { interval in
            let id = interval.rawSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, interval.startTime.isFinite, interval.endTime.isFinite,
                  interval.startTime >= 0, interval.endTime > interval.startTime else { return nil }
            return SpeakerInterval(rawSpeakerID: id, startTime: interval.startTime, endTime: interval.endTime)
        }.sorted { $0.startTime < $1.startTime }
        var end: TimeInterval = 0
        prefixEnds = intervals.map { end = max(end, $0.endTime); return end }
    }

    func evidence(start: TimeInterval, end: TimeInterval) -> SpeakerEvidence {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return .uncertain }
        // Binary search plus prefix maximum avoids scanning an entire long
        // meeting for each word. Only intervals intersecting this span count.
        var low = 0
        var high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if intervals[middle].startTime < end { low = middle + 1 } else { high = middle }
        }
        var bySpeaker: [String: [Range<TimeInterval>]] = [:]
        var cursor = low
        while cursor > 0, prefixEnds[cursor - 1] > start {
            cursor -= 1
            let interval = intervals[cursor]
            let lower = max(start, interval.startTime)
            let upper = min(end, interval.endTime)
            if lower < upper { bySpeaker[interval.rawSpeakerID, default: []].append(lower..<upper) }
        }
        var totals: [(String, TimeInterval)] = []
        var events: [(TimeInterval, Int)] = []
        for (id, ranges) in bySpeaker {
            let merged = Self.union(ranges)
            totals.append((id, merged.reduce(0) { $0 + $1.upperBound - $1.lowerBound }))
            for range in merged {
                events.append((range.lowerBound, 1))
                events.append((range.upperBound, -1))
            }
        }
        var simultaneous: TimeInterval = 0
        var previous = start
        var active = 0
        for (time, change) in events.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
            if active > 1 { simultaneous += time - previous }
            previous = time
            active += change
        }
        let duration = end - start
        if simultaneous >= max(0.08, duration * 0.2) {
            return SpeakerEvidence(rawSpeakerID: nil, status: .overlapping)
        }
        totals.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let best = totals.first else { return .uncertain }
        let runnerUp = totals.dropFirst().first?.1 ?? 0
        // Coverage/margin are conservative attribution rules, not calibrated
        // confidence probabilities. Insufficient evidence stays unassigned.
        guard best.1 / duration >= 0.55, (best.1 - runnerUp) / duration >= 0.15 else { return .uncertain }
        return SpeakerEvidence(rawSpeakerID: best.0, status: .attributed)
    }

    private static func union(_ ranges: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        var result: [Range<TimeInterval>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }
}
