import Foundation

struct CanonicalTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let transcriptIDs: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
    let isManuallyEdited: Bool
}

@MainActor
enum TranscriptCorrectionResolver {
    private static let minimumMutualCoverage = 0.5

    static func resolve(
        transcripts: [TranscriptRecord],
        corrections: [TranscriptCorrectionRecord]
    ) -> [CanonicalTranscriptEntry] {
        let orderedTranscripts = transcripts.sorted(by: transcriptComesBefore)
        let orderedCorrections = corrections.sorted(by: correctionComesBefore)
        let storedTranscriptIDs = orderedCorrections.map(\.transcriptIDs)
        let transcriptIndexByID = orderedTranscripts.indices.reduce(
            into: [UUID: Int]()
        ) { result, index in
            result[orderedTranscripts[index].id] = index
        }
        var availableIndices = Set(orderedTranscripts.indices)
        var matches: [Int: [Int]] = [:]

        for correctionIndex in orderedCorrections.indices {
            let targetIDs = Set(storedTranscriptIDs[correctionIndex])
            guard !targetIDs.isEmpty else { continue }

            let matchingIndices = targetIDs.compactMap {
                transcriptIndexByID[$0]
            }.sorted()
            guard matchingIndices.count == targetIDs.count,
                  matchingIndices.allSatisfy(availableIndices.contains) else {
                continue
            }

            matches[correctionIndex] = matchingIndices
            availableIndices.subtract(matchingIndices)
        }

        let fallbackCandidates = orderedCorrections.indices.reduce(
            into: [Int: [[Int]]]()
        ) { result, correctionIndex in
            guard matches[correctionIndex] == nil else { return }
            result[correctionIndex] = fallbackCandidateGroups(
                correction: orderedCorrections[correctionIndex],
                expectedCount: Set(storedTranscriptIDs[correctionIndex]).count,
                transcripts: orderedTranscripts,
                availableIndices: availableIndices
            )
        }
        let candidateOwners = fallbackCandidates.reduce(
            into: [Int: Set<Int>]()
        ) { result, candidate in
            let correctionIndex = candidate.key
            for transcriptIndex in Set(candidate.value.flatMap { $0 }) {
                result[transcriptIndex, default: []].insert(correctionIndex)
            }
        }
        for correctionIndex in orderedCorrections.indices {
            guard let candidateGroups = fallbackCandidates[correctionIndex],
                  candidateGroups.count == 1,
                  let candidate = candidateGroups.first,
                  candidate.allSatisfy({
                      candidateOwners[$0] == Set([correctionIndex])
                  }) else {
                continue
            }
            matches[correctionIndex] = candidate
            availableIndices.subtract(candidate)
        }

        var entries: [PositionedEntry] = []
        for index in availableIndices.sorted() {
            let transcript = orderedTranscripts[index]
            entries.append(
                PositionedEntry(
                    entry: CanonicalTranscriptEntry(
                        id: transcript.id,
                        transcriptIDs: [transcript.id],
                        startTime: transcript.startTime,
                        endTime: transcript.endTime,
                        text: transcript.text,
                        speakerID: transcript.speakerID,
                        source: transcript.source,
                        isManuallyEdited: false
                    ),
                    sequenceIndex: transcript.sequenceIndex
                )
            )
        }

        for correctionIndex in orderedCorrections.indices {
            let correction = orderedCorrections[correctionIndex]
            if let matchingIndices = matches[correctionIndex] {
                let matchedTranscripts = matchingIndices.map {
                    orderedTranscripts[$0]
                }
                entries.append(
                    PositionedEntry(
                        entry: correctedEntry(
                            correction: correction,
                            matchedTranscripts: matchedTranscripts
                        ),
                        sequenceIndex: matchedTranscripts
                            .compactMap(\.sequenceIndex)
                            .min()
                    )
                )
            } else {
                entries.append(
                    PositionedEntry(
                        entry: CanonicalTranscriptEntry(
                            id: correction.id,
                            transcriptIDs: storedTranscriptIDs[correctionIndex],
                            startTime: correction.anchorStartTime,
                            endTime: correction.anchorEndTime,
                            text: correction.replacementText,
                            speakerID: nil,
                            source: correction.source,
                            isManuallyEdited: true
                        ),
                        sequenceIndex: nil
                    )
                )
            }
        }

        return entries.sorted(by: positionedEntryComesBefore).map(\.entry)
    }

    /// Fallback reattachment is deliberately conservative. A candidate must
    /// contain the same number of rows as the stored correction, use consecutive
    /// rows in that source's chronological/sequence order, and its combined
    /// span must overlap at least half of both the old anchor and the new span.
    private static func fallbackCandidateGroups(
        correction: TranscriptCorrectionRecord,
        expectedCount: Int,
        transcripts: [TranscriptRecord],
        availableIndices: Set<Int>
    ) -> [[Int]] {
        guard expectedCount > 0 else { return [] }
        let sameSourceIndices = transcripts.indices.filter {
            transcripts[$0].source == correction.source
        }
        guard sameSourceIndices.count >= expectedCount else { return [] }

        return (0...(sameSourceIndices.count - expectedCount)).compactMap {
            startIndex in
            let endIndex = startIndex + expectedCount
            let candidate = Array(sameSourceIndices[startIndex..<endIndex])
            guard let candidateStart = candidate.map({
                transcripts[$0].startTime
            }).min(),
                  let candidateEnd = candidate.map({
                      transcripts[$0].endTime
                  }).max(),
                  candidate.allSatisfy(availableIndices.contains),
                  candidate.allSatisfy({
                      overlaps(
                          transcriptStart: transcripts[$0].startTime,
                          transcriptEnd: transcripts[$0].endTime,
                          anchorStart: correction.anchorStartTime,
                          anchorEnd: correction.anchorEndTime
                      )
                  }),
                  hasCompatibleCoverage(
                      anchorStart: correction.anchorStartTime,
                      anchorEnd: correction.anchorEndTime,
                      candidateStart: candidateStart,
                      candidateEnd: candidateEnd
                  ) else {
                return nil
            }
            return candidate
        }
    }

    private static func hasCompatibleCoverage(
        anchorStart: TimeInterval,
        anchorEnd: TimeInterval,
        candidateStart: TimeInterval,
        candidateEnd: TimeInterval
    ) -> Bool {
        guard anchorStart.isFinite,
              anchorEnd.isFinite,
              candidateStart.isFinite,
              candidateEnd.isFinite else {
            return false
        }
        let anchorDuration = anchorEnd - anchorStart
        let candidateDuration = candidateEnd - candidateStart
        guard anchorDuration > 0, candidateDuration > 0 else { return false }

        let overlapDuration = max(
            0,
            min(anchorEnd, candidateEnd) - max(anchorStart, candidateStart)
        )
        return overlapDuration / anchorDuration >= minimumMutualCoverage
            && overlapDuration / candidateDuration >= minimumMutualCoverage
    }

    private static func correctedEntry(
        correction: TranscriptCorrectionRecord,
        matchedTranscripts: [TranscriptRecord]
    ) -> CanonicalTranscriptEntry {
        let speakerIDs = Set(matchedTranscripts.map(\.speakerID))
        let speakerID = speakerIDs.count == 1
            ? speakerIDs.first.flatMap { $0 }
            : nil
        return CanonicalTranscriptEntry(
            id: correction.id,
            transcriptIDs: matchedTranscripts.map(\.id),
            startTime: matchedTranscripts.map(\.startTime).min()
                ?? correction.anchorStartTime,
            endTime: matchedTranscripts.map(\.endTime).max()
                ?? correction.anchorEndTime,
            text: correction.replacementText,
            speakerID: speakerID,
            source: correction.source,
            isManuallyEdited: true
        )
    }

    private static func overlaps(
        transcriptStart: TimeInterval,
        transcriptEnd: TimeInterval,
        anchorStart: TimeInterval,
        anchorEnd: TimeInterval
    ) -> Bool {
        max(transcriptStart, anchorStart) < min(transcriptEnd, anchorEnd)
    }

    private static func transcriptComesBefore(
        _ lhs: TranscriptRecord,
        _ rhs: TranscriptRecord
    ) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        switch (lhs.sequenceIndex, rhs.sequenceIndex) {
        case let (lhsSequence?, rhsSequence?) where lhsSequence != rhsSequence:
            return lhsSequence < rhsSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func correctionComesBefore(
        _ lhs: TranscriptCorrectionRecord,
        _ rhs: TranscriptCorrectionRecord
    ) -> Bool {
        if lhs.anchorStartTime != rhs.anchorStartTime {
            return lhs.anchorStartTime < rhs.anchorStartTime
        }
        if lhs.anchorEndTime != rhs.anchorEndTime {
            return lhs.anchorEndTime < rhs.anchorEndTime
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func positionedEntryComesBefore(
        _ lhs: PositionedEntry,
        _ rhs: PositionedEntry
    ) -> Bool {
        if lhs.entry.startTime != rhs.entry.startTime {
            return lhs.entry.startTime < rhs.entry.startTime
        }
        switch (lhs.sequenceIndex, rhs.sequenceIndex) {
        case let (lhsSequence?, rhsSequence?) where lhsSequence != rhsSequence:
            return lhsSequence < rhsSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.entry.endTime != rhs.entry.endTime {
            return lhs.entry.endTime < rhs.entry.endTime
        }
        return lhs.entry.id.uuidString < rhs.entry.id.uuidString
    }

    private struct PositionedEntry {
        let entry: CanonicalTranscriptEntry
        let sequenceIndex: Int?
    }
}
