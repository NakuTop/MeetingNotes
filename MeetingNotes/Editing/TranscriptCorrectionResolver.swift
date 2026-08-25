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

enum TranscriptCorrectionResolver {
    static func resolve(
        transcripts: [TranscriptRecord],
        corrections: [TranscriptCorrectionRecord]
    ) -> [CanonicalTranscriptEntry] {
        let orderedTranscripts = transcripts.sorted(by: transcriptComesBefore)
        let orderedCorrections = corrections.sorted(by: correctionComesBefore)
        var availableIndices = Set(orderedTranscripts.indices)
        var matches: [UUID: [Int]] = [:]

        for correction in orderedCorrections {
            let targetIDs = Set(correction.transcriptIDs)
            guard !targetIDs.isEmpty else { continue }

            let matchingIndices = orderedTranscripts.indices.filter {
                targetIDs.contains(orderedTranscripts[$0].id)
            }
            let foundIDs = Set(matchingIndices.map { orderedTranscripts[$0].id })
            guard foundIDs == targetIDs,
                  matchingIndices.allSatisfy(availableIndices.contains) else {
                continue
            }

            matches[correction.id] = matchingIndices
            availableIndices.subtract(matchingIndices)
        }

        for correction in orderedCorrections where matches[correction.id] == nil {
            let expectedCount = Set(correction.transcriptIDs).count
            guard expectedCount > 0 else { continue }

            let matchingIndices = availableIndices
                .filter {
                    let transcript = orderedTranscripts[$0]
                    return transcript.source == correction.source
                        && overlaps(
                            transcriptStart: transcript.startTime,
                            transcriptEnd: transcript.endTime,
                            anchorStart: correction.anchorStartTime,
                            anchorEnd: correction.anchorEndTime
                        )
                }
                .sorted()

            guard matchingIndices.count == expectedCount else { continue }
            matches[correction.id] = matchingIndices
            availableIndices.subtract(matchingIndices)
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

        for correction in orderedCorrections {
            if let matchingIndices = matches[correction.id] {
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
                            transcriptIDs: correction.transcriptIDs,
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
