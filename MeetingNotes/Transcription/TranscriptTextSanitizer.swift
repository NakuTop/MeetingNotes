import Foundation

enum TranscriptTextSanitizer {
    static func clean(_ text: String) -> String {
        var remainder = text[...]
        var fragments: [Substring] = []

        while let opening = remainder.range(of: "<|") {
            fragments.append(remainder[..<opening.lowerBound])
            let afterOpening = remainder[opening.upperBound...]
            guard let closing = afterOpening.range(of: "|>") else {
                fragments.append(remainder[opening.lowerBound...])
                remainder = ""[...]
                break
            }
            remainder = afterOpening[closing.upperBound...]
        }
        fragments.append(remainder)

        return fragments
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func nonEmpty(_ text: String) -> String? {
        let cleaned = clean(text)
        return cleaned.isEmpty ? nil : cleaned
    }
}
