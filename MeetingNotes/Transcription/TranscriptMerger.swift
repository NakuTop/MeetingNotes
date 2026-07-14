import Foundation

struct TranscriptMerger: Sendable {
    private let minimumOverlapLength: Int

    init(minimumOverlapLength: Int = 2) {
        self.minimumOverlapLength = max(1, minimumOverlapLength)
    }

    func merge(_ drafts: [TranscriptDraft]) -> [TranscriptDraft] {
        let ordered = drafts.enumerated().sorted { left, right in
            if left.element.startTime == right.element.startTime {
                if left.element.endTime == right.element.endTime {
                    return left.offset < right.offset
                }
                return left.element.endTime < right.element.endTime
            }
            return left.element.startTime < right.element.startTime
        }

        var result: [TranscriptDraft] = []
        for (_, draft) in ordered {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let deduplicated = result.last.map {
                removingBoundaryOverlap(previous: $0.text, current: text)
            } ?? text
            let cleaned = deduplicated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                continue
            }

            result.append(
                TranscriptDraft(
                    startTime: draft.startTime,
                    endTime: draft.endTime,
                    text: cleaned
                )
            )
        }
        return result
    }

    private func removingBoundaryOverlap(
        previous: String,
        current: String
    ) -> String {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let maximumLength = min(previousCharacters.count, currentCharacters.count)
        guard maximumLength >= minimumOverlapLength else {
            return current
        }

        for length in stride(
            from: maximumLength,
            through: minimumOverlapLength,
            by: -1
        ) {
            if previousCharacters.suffix(length) == currentCharacters.prefix(length) {
                return String(currentCharacters.dropFirst(length))
            }
        }
        return current
    }
}
