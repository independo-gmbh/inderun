package app.independo.inderun.providers.neuralspeech

import java.text.Normalizer

/** The text frontend every neural speech pipeline shares: sentences first, then tokens. */
object SpeechTextFrontend {
    /** `.`, `!`, `?` and `…` (U+2026), as code points so no editor can rewrite them. */
    private val terminators: Set<Int> = setOf(0x2E, 0x21, 0x3F, 0x2026)

    private fun isTerminator(char: Char): Boolean = char.code in terminators

    /**
     * Splits text into sentences, identically on all three SDKs (pinned by
     * `contracts/fixtures/speech/neural-frontend.json`).
     *
     * The text is normalized to NFC and split at `\n`; each line is split after a run of `.`, `!`,
     * `?` or `…` that is followed by whitespace or the end of the line. Pieces are trimmed, internal
     * whitespace is collapsed to one space and empty pieces are dropped. Text without a boundary is
     * one sentence. Pipeline-specific normalizers (numbers, abbreviations) are not applied here.
     */
    fun splitSentences(text: String): List<String> {
        val sentences = mutableListOf<String>()
        for (line in Normalizer.normalize(text, Normalizer.Form.NFC).split('\n')) {
            var start = 0
            var index = 0
            while (index < line.length) {
                if (!isTerminator(line[index])) {
                    index += 1
                    continue
                }
                var end = index
                while (end < line.length && isTerminator(line[end])) end += 1
                if (end == line.length || isWhitespace(line[end])) {
                    append(line, start, end, sentences)
                    start = end
                }
                index = end
            }
            append(line, start, line.length, sentences)
        }
        return sentences
    }

    /** Appends `line[start, end)` trimmed and with its whitespace runs collapsed, unless empty. */
    private fun append(line: String, start: Int, end: Int, sentences: MutableList<String>) {
        val cleaned = StringBuilder()
        var pendingSpace = false
        for (index in start until end) {
            val char = line[index]
            if (isWhitespace(char)) {
                pendingSpace = cleaned.isNotEmpty()
                continue
            }
            if (pendingSpace) {
                cleaned.append(' ')
                pendingSpace = false
            }
            cleaned.append(char)
        }
        if (cleaned.isNotEmpty()) sentences += cleaned.toString()
    }

    /**
     * Exactly the code points ECMAScript's `\s` matches, so the rule splits identically on every
     * SDK: U+0009-U+000D, U+0020, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F,
     * U+3000 and U+FEFF. Java's `\s` (ASCII only) and [Character.isWhitespace] (which leaves out
     * U+00A0 and U+202F, and holds U+001C-U+001F) both differ from it. Every member is in the BMP,
     * so a UTF-16 unit is enough to test; a surrogate is never whitespace.
     */
    internal fun isWhitespace(char: Char): Boolean = char.code in whitespace

    /** The set above as code points, written in hex so no editor or formatter can rewrite them. */
    private val whitespace: Set<Int> = buildSet {
        addAll(0x0009..0x000D)
        add(0x0020)
        add(0x00A0)
        add(0x1680)
        addAll(0x2000..0x200A)
        add(0x2028)
        add(0x2029)
        add(0x202F)
        add(0x205F)
        add(0x3000)
        add(0xFEFF)
    }
}

/**
 * Grapheme tokenizer: lowercases the sentence (locale-independently), maps each code point through
 * the vocabulary and drops code points the vocabulary lacks.
 */
class GraphemeTokenizer(private val vocab: Map<String, Int>) {
    fun encode(sentence: String): List<Int> {
        val lowered = Normalizer.normalize(sentence, Normalizer.Form.NFC).lowercase()
        val ids = mutableListOf<Int>()
        lowered.codePoints().forEach { codePoint ->
            vocab[String(Character.toChars(codePoint))]?.let { ids += it }
        }
        return ids
    }
}
