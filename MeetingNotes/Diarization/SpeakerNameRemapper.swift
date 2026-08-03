import Foundation

struct SpeakerNameEvidenceInterval: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: TranscriptAudioSource
}

struct SpeakerNameEvidence: Equatable, Sendable {
    let speakerID: String
    let displayName: String
    let intervals: [SpeakerNameEvidenceInterval]
}

struct SpeakerNameRemapper: Sendable {
    private let minimumCoverage: Double
    private let minimumWinnerMargin: Double

    init(
        minimumCoverage: Double = 0.60,
        minimumWinnerMargin: Double = 0.15
    ) {
        self.minimumCoverage = minimumCoverage
        self.minimumWinnerMargin = minimumWinnerMargin
    }

    func remap(
        oldNamedSpeakers: [SpeakerNameEvidence],
        newDrafts: [AttributedTranscriptDraft]
    ) -> [String: String] {
        let newSpeakers = Dictionary(
            grouping: newDrafts.filter { $0.speakerID != nil },
            by: { $0.speakerID ?? "" }
        )
        let candidates: [Candidate] = oldNamedSpeakers
            .sorted { lhs, rhs in
                if lhs.speakerID != rhs.speakerID {
                    return lhs.speakerID < rhs.speakerID
                }
                return lhs.displayName < rhs.displayName
            }
            .compactMap { evidence -> Candidate? in
                let positiveIntervals = evidence.intervals.filter {
                    $0.endTime > $0.startTime
                }
                let totalDuration: TimeInterval = positiveIntervals.reduce(
                    0.0
                ) {
                    (partial: TimeInterval, interval) in
                    partial + (interval.endTime - interval.startTime)
                }
                guard totalDuration > 0 else { return nil }

                let scores: [SpeakerScore] = newSpeakers.map {
                    speakerID, items in
                    let overlap: TimeInterval = positiveIntervals.reduce(
                        0.0
                    ) {
                        (partial: TimeInterval, oldInterval) in
                        partial + items.reduce(0.0) {
                            (itemPartial: TimeInterval, item) in
                            guard oldInterval.source == item.source else {
                                return itemPartial
                            }
                            return itemPartial + Self.overlap(
                                startA: oldInterval.startTime,
                                endA: oldInterval.endTime,
                                startB: item.transcript.startTime,
                                endB: item.transcript.endTime
                            )
                        }
                    }
                    return SpeakerScore(
                        speakerID: speakerID,
                        coverage: overlap / totalDuration
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.coverage != rhs.coverage {
                        return lhs.coverage > rhs.coverage
                    }
                    return lhs.speakerID < rhs.speakerID
                }

                guard let winner = scores.first,
                      winner.coverage >= minimumCoverage else {
                    return nil
                }
                let runnerUpCoverage = scores.dropFirst().first?.coverage ?? 0
                guard winner.coverage - runnerUpCoverage
                        >= minimumWinnerMargin else {
                    return nil
                }
                return Candidate(
                    newSpeakerID: winner.speakerID,
                    displayName: evidence.displayName
                )
            }

        let candidatesByNewSpeaker = Dictionary(
            grouping: candidates,
            by: \.newSpeakerID
        )
        return candidatesByNewSpeaker.reduce(into: [:]) { result, item in
            guard item.value.count == 1,
                  let candidate = item.value.first else {
                return
            }
            result[item.key] = candidate.displayName
        }
    }

    private static func overlap(
        startA: TimeInterval,
        endA: TimeInterval,
        startB: TimeInterval,
        endB: TimeInterval
    ) -> TimeInterval {
        max(0, min(endA, endB) - max(startA, startB))
    }
}

private struct Candidate {
    let newSpeakerID: String
    let displayName: String
}

private struct SpeakerScore {
    let speakerID: String
    let coverage: Double
}
