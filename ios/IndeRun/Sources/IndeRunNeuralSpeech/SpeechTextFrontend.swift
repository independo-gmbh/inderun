import Foundation

/// The text frontend every neural speech pipeline shares: sentences first, then tokens.
public enum SpeechTextFrontend {
    private static let terminators: Set<Unicode.Scalar> = [".", "!", "?", "\u{2026}"]

    /// Splits text into sentences, identically on all three SDKs (pinned by
    /// `contracts/fixtures/speech/neural-frontend.json`).
    ///
    /// The text is normalized to NFC and split at `\n`; each line is split after a run of `.`, `!`,
    /// `?` or `…` that is followed by whitespace or the end of the line. Pieces are trimmed,
    /// internal whitespace is collapsed to one space and empty pieces are dropped. Text without a
    /// boundary is one sentence. Pipeline-specific normalizers (numbers, abbreviations) are not
    /// applied here.
    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let normalized = text.precomposedStringWithCanonicalMapping
        for line in normalized.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let scalars = Array(line)
            var start = 0
            var index = 0
            while index < scalars.count {
                guard terminators.contains(scalars[index]) else {
                    index += 1
                    continue
                }
                var end = index
                while end < scalars.count, terminators.contains(scalars[end]) {
                    end += 1
                }
                if end == scalars.count || isWhitespace(scalars[end]) {
                    append(scalars[start ..< end], to: &sentences)
                    start = end
                }
                index = end
            }
            append(scalars[start...], to: &sentences)
        }
        return sentences
    }

    private static func append(_ piece: ArraySlice<Unicode.Scalar>, to sentences: inout [String]) {
        var cleaned = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in piece {
            if isWhitespace(scalar) {
                pendingSpace = !cleaned.isEmpty
                continue
            }
            if pendingSpace {
                cleaned.append(" ")
                pendingSpace = false
            }
            cleaned.append(scalar)
        }
        if !cleaned.isEmpty { sentences.append(String(cleaned)) }
    }

    /// Exactly the code points ECMAScript's `\s` matches, so the rule splits identically on every
    /// SDK: U+0009-U+000D, U+0020, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F,
    /// U+3000 and U+FEFF. Unicode `White_Space` is not used: it also holds U+0085 (NEL), which `\s`
    /// does not.
    private static let whitespace: Set<Unicode.Scalar> = {
        let ranges: [ClosedRange<UInt32>] = [
            0x0009 ... 0x000D, 0x0020 ... 0x0020, 0x00A0 ... 0x00A0, 0x1680 ... 0x1680, 0x2000 ... 0x200A,
            0x2028 ... 0x2029, 0x202F ... 0x202F, 0x205F ... 0x205F, 0x3000 ... 0x3000, 0xFEFF ... 0xFEFF
        ]
        return Set(ranges.flatMap { $0.compactMap(Unicode.Scalar.init) })
    }()

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        whitespace.contains(scalar)
    }
}

/// Grapheme tokenizer: lowercases the sentence, maps each code point through the vocabulary and
/// drops code points the vocabulary lacks.
public struct GraphemeTokenizer: Sendable {
    private let vocab: [String: Int]

    public init(vocab: [String: Int]) {
        self.vocab = vocab
    }

    public func encode(_ sentence: String) -> [Int] {
        sentence.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.compactMap { vocab[String($0)] }
    }
}
