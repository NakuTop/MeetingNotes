import Foundation

struct SpeakerIntervalAssigner: Sendable {
    func assign(
        _ drafts: [TranscriptDraft],
        intervals: [SpeakerInterval],
        speakerPrefix: String,
        source: TranscriptAudioSource,
        refinements: [SpeakerRefinedRegion] = []
    ) -> [AttributedTranscriptDraft] {
        let index = SpeakerEvidenceIndex(intervals)
        let localIndexes = refinements.map { ($0, SpeakerEvidenceIndex($0.intervals)) }
        func resolved(start: Double, end: Double) -> SpeakerEvidence {
            let original = index.evidence(start: start, end: end)
            guard original.status == .uncertain else { return original }
            var candidates: [(SpeakerReferenceMatch, SpeakerEvidence)] = []
            var hasUnresolvedLocalEvidence = false
            for (region, localIndex) in localIndexes where region.span.start <= start && region.span.end >= end {
                let local = localIndex.evidence(start: start, end: end)
                // Keep all local voices in the index: overlapping or competing
                // speech must never turn into a single confident speaker.
                if local.status == .overlapping {
                    return .init(rawSpeakerID: nil, status: .overlapping, hint: .init(
                        candidateSpeakerID: local.hint?.candidateSpeakerID.flatMap { region.matches[$0]?.rawSpeakerID }
                            ?? original.rawSpeakerID ?? original.hint?.candidateSpeakerID,
                        alternativeSpeakerID: local.hint?.alternativeSpeakerID.flatMap { region.matches[$0]?.rawSpeakerID },
                        reason: .overlapping))
                }
                guard local.status == .attributed, let id = local.rawSpeakerID,
                      let match = region.matches[id] else { hasUnresolvedLocalEvidence = true; continue }
                candidates.append((match, local))
            }
            guard let best = candidates.first,
                  Set(candidates.map { $0.0.rawSpeakerID }).count == 1 else { return original }
            let agreesWithOriginal = original.hint?.candidateSpeakerID == nil ||
                original.hint?.candidateSpeakerID == best.0.rawSpeakerID
            let allStrong = !hasUnresolvedLocalEvidence && candidates.allSatisfy {
                $0.0.isStrong && $0.1.coverage >= 0.8 && $0.1.margin >= 0.5
            }
            if allStrong, agreesWithOriginal, original.hint?.reason != .competingSpeakers {
                return .init(rawSpeakerID: best.0.rawSpeakerID, status: .attributed)
            }
            return .init(rawSpeakerID: nil, status: .uncertain, hint: .init(
                candidateSpeakerID: best.0.rawSpeakerID,
                alternativeSpeakerID: agreesWithOriginal ? nil : original.hint?.candidateSpeakerID,
                reason: .acousticCandidate, basis: .meetingVoice,
                coverage: candidates.map { $0.1.coverage }.min() ?? 0,
                margin: candidates.map { $0.1.margin }.min() ?? 0))
        }
        let pieces = drafts.flatMap { draft -> [(TranscriptDraft, SpeakerEvidence, TranscriptAttributionOrigin)] in
            let origin = TranscriptAttributionOrigin(startTime: draft.startTime, endTime: draft.endTime, text: draft.text)
            guard let units = TranscriptWordAlignment.units(in: draft) else {
                return [(draft, resolved(start: draft.startTime, end: draft.endTime), origin)]
            }
            var groups: [(Range<Int>, SpeakerEvidence)] = []
            for unitIndex in units.indices {
                let word = units[unitIndex].word
                let evidence = resolved(start: word.startTime, end: word.endTime)
                if let last = groups.last, last.1.canCombine(with: evidence) {
                    groups[groups.count - 1].0 = last.0.lowerBound..<(unitIndex + 1)
                    groups[groups.count - 1].1 = last.1.combined(with: evidence)
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
        // Candidate-only voices get stable anonymous IDs too, without shifting
        // the numbering of already-attributed speakers.
        for index in chronological {
            for rawID in [pieces[index].1.hint?.candidateSpeakerID, pieces[index].1.hint?.alternativeSpeakerID].compactMap({ $0 })
            where stableIDs[rawID] == nil {
                stableIDs[rawID] = "\(speakerPrefix)-\(stableIDs.count + 1)"
            }
        }
        var automaticIDs: [Int: String] = [:]
        var previousRawID: String?
        for position in chronological {
            let (draft, evidence, _) = pieces[position]
            let raw = index.bestEffortSpeaker(start: draft.startTime, end: draft.endTime,
                preferring: previousRawID, evidence: evidence) ?? previousRawID ?? "\u{0}unobserved"
            if stableIDs[raw] == nil { stableIDs[raw] = "\(speakerPrefix)-\(stableIDs.count + 1)" }
            automaticIDs[position] = stableIDs[raw]
            previousRawID = raw
        }
        return pieces.enumerated().map { position, piece in
            let (draft, evidence, origin) = piece
            return AttributedTranscriptDraft(
                transcript: draft, speakerID: automaticIDs[position], source: source,
                attributionStatus: evidence.status == .uncertain ? .inferred : evidence.status, attributionOrigin: origin,
                reviewHint: evidence.hint?.remapping(stableIDs)
            )
        }
    }

    func assignedRawSpeakerIDs(_ drafts: [TranscriptDraft], intervals: [SpeakerInterval]) -> [String?] {
        let index = SpeakerEvidenceIndex(intervals)
        return drafts.map { index.evidence(start: $0.startTime, end: $0.endTime).rawSpeakerID }
    }
}

struct SpeakerEvidence: Equatable {
    let rawSpeakerID: String?
    let status: SpeakerAttributionStatus
    var hint: SpeakerReviewHint? = nil
    var coverage: Double = 0
    var margin: Double = 0
    static let uncertain = Self(rawSpeakerID: nil, status: .uncertain,
        hint: .init(candidateSpeakerID: nil, reason: .invalidTiming))

    func canCombine(with other: Self) -> Bool {
        rawSpeakerID == other.rawSpeakerID && status == other.status &&
            hint?.candidateSpeakerID == other.hint?.candidateSpeakerID &&
            hint?.alternativeSpeakerID == other.hint?.alternativeSpeakerID &&
            hint?.reason == other.hint?.reason && hint?.basis == other.hint?.basis
    }

    func combined(with other: Self) -> Self {
        var result = self
        result.coverage = min(coverage, other.coverage)
        result.margin = min(margin, other.margin)
        if result.hint != nil {
            result.hint?.coverage = min(hint?.coverage ?? 0, other.hint?.coverage ?? 0)
            result.hint?.margin = min(hint?.margin ?? 0, other.hint?.margin ?? 0)
        }
        return result
    }
}

struct SpeakerEvidenceIndex {
    private let intervals: [SpeakerInterval]
    private let prefixEnds: [TimeInterval]
    private let byEnd: [SpeakerInterval]

    init(_ input: [SpeakerInterval]) {
        intervals = input.compactMap { interval in
            let id = interval.rawSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, interval.startTime.isFinite, interval.endTime.isFinite,
                  interval.startTime >= 0, interval.endTime > interval.startTime else { return nil }
            return SpeakerInterval(rawSpeakerID: id, startTime: interval.startTime, endTime: interval.endTime)
        }.sorted { $0.startTime == $1.startTime ? $0.rawSpeakerID < $1.rawSpeakerID : $0.startTime < $1.startTime }
        byEnd = intervals.sorted {
            $0.endTime == $1.endTime ? $0.rawSpeakerID < $1.rawSpeakerID : $0.endTime < $1.endTime
        }
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
        totals.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        if simultaneous >= max(0.08, duration * 0.2) {
            return SpeakerEvidence(rawSpeakerID: nil, status: .overlapping,
                hint: .init(candidateSpeakerID: totals.first?.0,
                    alternativeSpeakerID: totals.dropFirst().first?.0, reason: .overlapping))
        }
        guard let best = totals.first else {
            return .init(rawSpeakerID: nil, status: .uncertain,
                hint: .init(candidateSpeakerID: nil, reason: .missingSpeech))
        }
        let runnerUp = totals.dropFirst().first?.1 ?? 0
        // Coverage/margin are conservative attribution rules, not calibrated
        // confidence probabilities. Insufficient evidence stays unassigned.
        let coverage = best.1 / duration
        let margin = (best.1 - runnerUp) / duration
        guard coverage >= 0.55, margin >= 0.15 else {
            return .init(rawSpeakerID: nil, status: .uncertain, hint: .init(
                candidateSpeakerID: best.0, alternativeSpeakerID: totals.dropFirst().first?.0,
                reason: margin < 0.15 ? .competingSpeakers : .insufficientCoverage,
                coverage: coverage, margin: margin), coverage: coverage, margin: margin)
        }
        return SpeakerEvidence(rawSpeakerID: best.0, status: .attributed, coverage: coverage, margin: margin)
    }

    /// Keep the evidence classification separate from the product's requirement
    /// to give every utterance a best estimate. Never consult another audio track.
    func bestEffortSpeaker(start: TimeInterval, end: TimeInterval,
                           preferring previous: String? = nil, evidence supplied: SpeakerEvidence? = nil) -> String? {
        let value = supplied ?? evidence(start: start, end: end)
        if let id = value.rawSpeakerID { return id }
        if let candidate = value.hint?.candidateSpeakerID {
            if value.hint?.reason == .competingSpeakers, abs(value.margin) < 0.000_001,
               let previous, value.hint?.alternativeSpeakerID == previous { return previous }
            return candidate
        }
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return previous }
        // No measured speech overlaps the text. Find the nearest real interval
        // in O(log n), retaining previous-speaker continuity on equal distances.
        var low = 0, high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].startTime < end { low = mid + 1 } else { high = mid }
        }
        let next = low < intervals.count ? intervals[low] : nil
        low = 0; high = byEnd.count
        while low < high {
            let mid = (low + high) / 2
            if byEnd[mid].endTime <= start { low = mid + 1 } else { high = mid }
        }
        let prior = low > 0 ? byEnd[low - 1] : nil
        if let prior, let next {
            return start - prior.endTime <= next.startTime - end ? prior.rawSpeakerID : next.rawSpeakerID
        }
        return prior?.rawSpeakerID ?? next?.rawSpeakerID ?? previous
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
