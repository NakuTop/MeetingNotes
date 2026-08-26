import Foundation

enum MeetingExactReplacementError: Error, Equatable, Sendable {
    case emptySearchText
    case identicalSearchAndReplacement
    case stalePreview(
        expectedContentRevision: Int,
        actualContentRevision: Int
    )
    case invalidStructuredField(String)
}

struct MeetingExactReplacementPreview: Equatable, Sendable {
    let meetingID: UUID
    let observedContentRevision: Int
    let searchText: String
    let replacementText: String
    let transcriptMatches: Int
    let speakerMatches: Int
    let summaryMatches: Int
    let detailedMinutesMatches: Int

    var totalMatches: Int {
        [
            transcriptMatches,
            speakerMatches,
            summaryMatches,
            detailedMinutesMatches
        ].reduce(0, Self.saturatingAdd)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

@MainActor
final class MeetingExactReplacement {
    private let repository: MeetingRepository

    init(repository: MeetingRepository) {
        self.repository = repository
    }

    func preview(
        meetingID: UUID,
        old: String,
        new: String
    ) throws -> MeetingExactReplacementPreview {
        try repository.previewExactReplacement(
            meetingID: meetingID,
            old: old,
            new: new
        )
    }

    func apply(
        _ confirmedPreview: MeetingExactReplacementPreview
    ) throws -> MeetingExactReplacementPreview {
        try repository.applyExactReplacement(
            confirmedPreview
        )
    }
}

struct MeetingExactTextReplacement {
    let value: String
    let matches: Int

    static func validate(old: String, new: String) throws {
        guard !old.isEmpty else {
            throw MeetingExactReplacementError.emptySearchText
        }
        guard old != new else {
            throw MeetingExactReplacementError.identicalSearchAndReplacement
        }
    }

    static func replacing(
        _ value: String,
        old: String,
        new: String
    ) -> MeetingExactTextReplacement {
        MeetingExactTextReplacement(
            value: value.replacingOccurrences(
                of: old,
                with: new,
                options: .literal
            ),
            matches: occurrenceCount(in: value, of: old)
        )
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func occurrenceCount(
        in value: String,
        of searchText: String
    ) -> Int {
        var count = 0
        var remaining = value.startIndex..<value.endIndex
        while let match = value.range(
            of: searchText,
            options: .literal,
            range: remaining
        ) {
            count = saturatingAdd(count, 1)
            remaining = match.upperBound..<value.endIndex
        }
        return count
    }
}
