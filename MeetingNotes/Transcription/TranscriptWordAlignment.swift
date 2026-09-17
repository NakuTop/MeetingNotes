import Foundation

enum TranscriptWordAlignment {
    struct Unit {
        let range: Range<String.Index>
        let word: TranscriptWordTiming
    }

    // Match actual Whisper tokens to the unchanged string. Never distribute
    // characters proportionally across time: that fabricates turn boundaries.
    static func units(in draft: TranscriptDraft) -> [Unit]? {
        guard !draft.words.isEmpty, draft.startTime.isFinite,
            draft.endTime.isFinite, draft.endTime > draft.startTime
        else { return nil }
        let text = draft.text
        var cursor = text.startIndex
        var previousStart = draft.startTime
        var result: [Unit] = []
        for word in draft.words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, word.startTime.isFinite, word.endTime.isFinite,
                word.startTime >= previousStart, word.endTime > word.startTime,
                word.startTime >= draft.startTime - 0.1,
                word.endTime <= draft.endTime + 0.1,
                let range = text.range(of: token, range: cursor..<text.endIndex),
                text[cursor..<range.lowerBound].allSatisfy({ $0.isWhitespace || $0.isPunctuation })
            else { return nil }
            result.append(Unit(range: cursor..<range.upperBound, word: word))
            cursor = range.upperBound
            previousStart = word.startTime
        }
        guard text[cursor...].allSatisfy({ $0.isWhitespace || $0.isPunctuation }),
            let last = result.popLast()
        else { return nil }
        result.append(Unit(range: last.range.lowerBound..<text.endIndex, word: last.word))
        return result
    }

    // Sanitization/deduplication may remove a prefix. Retain only timings that
    // still align to the complete retained text; ambiguous metadata is omitted.
    static func retainingWords(
        _ words: [TranscriptWordTiming], for text: String,
        startTime: TimeInterval, endTime: TimeInterval,
        removingPrefixFrom original: String? = nil
    ) -> [TranscriptWordTiming] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        let full = TranscriptDraft(startTime: startTime, endTime: endTime, text: text, words: words)
        if units(in: full) != nil { return words }
        // A suffix is safe only when the merger explicitly removed that
        // prefix from known original text. Merely finding a matching suffix
        // in inconsistent SDK metadata would invent a later timestamp.
        guard let original, original.count > text.count, original.hasSuffix(text),
              let originalUnits = units(in: TranscriptDraft(
                startTime: startTime, endTime: endTime, text: original, words: words)) else { return [] }
        let suffixStart = original.index(original.endIndex, offsetBy: -text.count)
        guard let index = originalUnits.firstIndex(where: {
            $0.range.contains(suffixStart)
                && original[$0.range.lowerBound..<suffixStart].allSatisfy(\.isWhitespace)
        }) else { return [] }
        let candidate = Array(words[index...])
        return units(in: TranscriptDraft(startTime: startTime, endTime: endTime, text: text, words: candidate)) == nil
            ? [] : candidate
    }
}
