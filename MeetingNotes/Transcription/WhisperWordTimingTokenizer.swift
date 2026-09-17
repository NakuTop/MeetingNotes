import Foundation
import NaturalLanguage
@preconcurrency import WhisperKit

// The pinned SDK compares NLLanguage raw values to "zh", but macOS reports
// "zh-Hans"/"zh-Hant". Its space-based fallback then aligns an entire Chinese
// sentence as one word. Only the timestamp token grouping is adapted here:
// ASR encode/decode, special tokens, language detection and model are untouched.
final class WhisperWordTimingTokenizer: WhisperTokenizer {
    private let base: any WhisperTokenizer

    init(base: any WhisperTokenizer) { self.base = base }

    var specialTokens: SpecialTokens { base.specialTokens }
    var allLanguageTokens: Set<Int> { base.allLanguageTokens }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let text = base.decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard Self.isChinese(recognizer.dominantLanguage?.rawValue) else {
            return base.splitToWordTokens(tokenIds: tokenIds)
        }
        let split = Self.unicodeGroups(tokens: tokenIds, decode: base.decode(tokens:))
        guard split.words.joined() == base.decode(tokens: tokenIds),
            split.wordTokens.flatMap({ $0 }) == tokenIds
        else {
            return base.splitToWordTokens(tokenIds: tokenIds)
        }
        return split
    }

    static func isChinese(_ language: String?) -> Bool {
        language?.split(separator: "-").first == "zh"
    }

    static func unicodeGroups(tokens: [Int], decode: ([Int]) -> String) -> (
        words: [String], wordTokens: [[Int]]
    ) {
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for token in tokens {
            pending.append(token)
            let decoded = decode(pending)
            // BPE byte fragments must stay together until they form valid
            // Unicode. Never assign fabricated proportional character times.
            if !decoded.isEmpty, !decoded.contains("\u{fffd}") {
                words.append(decoded)
                groups.append(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            words.append(decode(pending))
            groups.append(pending)
        }
        return (words, groups)
    }
}
