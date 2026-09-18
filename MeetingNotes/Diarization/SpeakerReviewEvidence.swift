import Foundation

enum SpeakerReviewReason: String, Codable, Sendable {
    case insufficientCoverage, competingSpeakers, missingSpeech, invalidTiming, overlapping, acousticCandidate

    var label: String {
        switch self {
        case .insufficientCoverage: "语音边界覆盖不足"
        case .competingSpeakers: "存在多个说话人候选"
        case .missingSpeech: "缺少可对应的清晰语音"
        case .invalidTiming: "字词时间证据不足"
        case .overlapping: "重叠发言"
        case .acousticCandidate: "本场声音相似，仍需试听确认"
        }
    }
}

struct SpeakerReviewHint: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable { case timeOverlap, meetingVoice }
    let candidateSpeakerID: String?
    var alternativeSpeakerID: String? = nil
    let reason: SpeakerReviewReason
    var basis: Basis = .timeOverlap
    // Temporal evidence, not a probability of identity.
    var coverage: Double = 0
    var margin: Double = 0

    var canGroupForReview: Bool {
        guard candidateSpeakerID != nil, coverage.isFinite, margin.isFinite else { return false }
        return (basis == .meetingVoice && alternativeSpeakerID == nil) ||
            (reason == .insufficientCoverage && coverage >= 0.35 && margin >= 0.25)
    }

    func canGroup(with other: Self) -> Bool {
        canGroupForReview && other.canGroupForReview && candidateSpeakerID == other.candidateSpeakerID &&
            alternativeSpeakerID == other.alternativeSpeakerID && reason == other.reason && basis == other.basis
    }

    static func consensus(_ hints: [Self?]) -> Self? {
        guard var first = hints.first ?? nil, hints.allSatisfy({ hint in
            guard let hint else { return false }
            return hint.candidateSpeakerID == first.candidateSpeakerID &&
                hint.alternativeSpeakerID == first.alternativeSpeakerID && hint.reason == first.reason && hint.basis == first.basis
        }) else { return nil }
        first.coverage = hints.compactMap { $0?.coverage }.min() ?? 0
        first.margin = hints.compactMap { $0?.margin }.min() ?? 0
        return first
    }

    func remapping(_ mapping: [String: String]) -> Self {
        Self(candidateSpeakerID: candidateSpeakerID.flatMap { mapping[$0] },
            alternativeSpeakerID: alternativeSpeakerID.flatMap { mapping[$0] }, reason: reason,
            basis: basis, coverage: coverage, margin: margin)
    }
}

struct SpeakerReviewSpan: Equatable, Sendable {
    let start: Double
    let end: Double

    static func measured(in drafts: [TranscriptDraft]) -> [Self] {
        drafts.flatMap { draft in
            if let units = TranscriptWordAlignment.units(in: draft) {
                return units.map { Self(start: $0.word.startTime, end: $0.word.endTime) }
            }
            return [Self(start: draft.startTime, end: draft.endTime)]
        }
    }
}

struct SpeakerReferenceMatch: Equatable, Sendable {
    let rawSpeakerID: String
    let isStrong: Bool
}

struct SpeakerRefinedRegion: Sendable {
    let span: SpeakerReviewSpan
    // Include unmatched voices too, so overlap/competition cannot disappear.
    let intervals: [SpeakerInterval]
    let matches: [String: SpeakerReferenceMatch]
}

struct SpeakerDiarizationAnalysis: Sendable {
    let intervals: [SpeakerInterval]
    var refinements: [SpeakerRefinedRegion] = []
}

enum SpeakerReviewWindowPlanner {
    static func windows(spans: [SpeakerReviewSpan], intervals: [SpeakerInterval], duration: Double,
                        maximumWindows: Int = 12, maximumAudioSeconds: Double = 120) -> [SpeakerReviewSpan] {
        guard duration.isFinite, duration >= 5, maximumWindows > 0 else { return [] }
        let evidence = SpeakerEvidenceIndex(intervals)
        var windows: [SpeakerReviewSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.end <= duration,
                  span.end > span.start, span.end - span.start <= 16,
                  evidence.evidence(start: span.start, end: span.end).status == .uncertain else { continue }
            let center = (span.start + span.end) / 2
            let width = min(duration, max(8, span.end - span.start + 4))
            let start = min(max(0, center - width / 2), duration - width)
            let next = SpeakerReviewSpan(start: start, end: start + width)
            if let last = windows.last, next.start <= last.end, next.end - last.start <= 20 {
                windows[windows.count - 1] = .init(start: last.start, end: max(last.end, next.end))
            } else { windows.append(next) }
        }
        var seconds: Double = 0
        return windows.prefix(maximumWindows).filter {
            guard seconds + $0.end - $0.start <= maximumAudioSeconds else { return false }
            seconds += $0.end - $0.start
            return true
        }
    }
}

enum MeetingSpeakerReferenceMatcher {
    static func match(_ vector: [Float], against references: [String: [Float]]) -> SpeakerReferenceMatch? {
        guard let normalized = try? VoiceprintQuality.normalized(vector) else { return nil }
        var scores: [(id: String, score: Float)] = []
        for (id, vector) in references {
            guard let reference = try? VoiceprintQuality.normalized(vector) else { continue }
            scores.append((id, VoiceprintQuality.similarity(normalized, reference)))
        }
        scores.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        guard let best = scores.first else { return nil }
        let margin = best.score - (scores.dropFirst().first?.score ?? -1)
        // Conservative initial gates, explicitly uncalibrated. Weaker matches
        // can only become human-review suggestions, never automatic labels.
        guard best.score >= 0.72, margin >= 0.08 else { return nil }
        return .init(rawSpeakerID: best.id, isStrong: best.score >= 0.85 && margin >= 0.12)
    }
}

struct SpeakerReferenceSegment: Sendable {
    let interval: SpeakerInterval
    let quality: Float
}

enum MeetingSpeakerReferencePolicy {
    // Only uncontested, sufficiently clear speech can qualify a meeting's
    // anonymous reference. No profile is written to the voiceprint library.
    static func eligibleIDs(_ segments: [SpeakerReferenceSegment]) -> Set<String> {
        var events: [(time: Double, index: Int, entering: Bool)] = []
        for (index, segment) in segments.enumerated() {
            let span = segment.interval
            guard span.startTime.isFinite, span.endTime.isFinite, span.startTime >= 0,
                  span.endTime > span.startTime else { continue }
            events.append((span.startTime, index, true))
            events.append((span.endTime, index, false))
        }
        events.sort { $0.time == $1.time ? (!$0.entering && $1.entering) : $0.time < $1.time }
        var counts: [String: Int] = [:]
        var clear: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        var previous: Double = 0
        for event in events {
            if counts.count == 1, let id = counts.keys.first, (clear[id] ?? 0) > 0 {
                seconds[id, default: 0] += event.time - previous
            }
            previous = event.time
            let segment = segments[event.index]
            let id = segment.interval.rawSpeakerID
            let change = event.entering ? 1 : -1
            counts[id, default: 0] += change
            if counts[id] == 0 { counts.removeValue(forKey: id) }
            if segment.quality.isFinite, segment.quality >= 0.5 {
                clear[id, default: 0] += change
            }
        }
        return Set(seconds.filter { $0.value >= 5 }.map(\.key))
    }
}
