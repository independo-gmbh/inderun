const TERMINATORS = new Set([".", "!", "?", "…"]);

const isWhitespace = (char: string): boolean => /\s/u.test(char);

/**
 * Splits text into sentences, identically on all three SDKs (pinned by
 * `contracts/fixtures/speech/neural-frontend.json`).
 *
 * The text is normalized to NFC and split at `\n`; each line is split after a run of `.`, `!`,
 * `?` or `…` that is followed by whitespace or the end of the text. Pieces are trimmed, internal
 * whitespace is collapsed to one space and empty pieces are dropped. Text without a boundary is
 * one sentence. Pipeline-specific normalizers (numbers, abbreviations) are not applied here.
 */
export function splitSentences(text: string): string[] {
  const sentences: string[] = [];
  const push = (piece: string): void => {
    const cleaned = piece.replace(/\s+/gu, " ").trim();
    if (cleaned.length > 0) sentences.push(cleaned);
  };

  for (const line of text.normalize("NFC").split("\n")) {
    let start = 0;
    let index = 0;
    while (index < line.length) {
      if (!TERMINATORS.has(line.charAt(index))) {
        index += 1;
        continue;
      }
      let end = index;
      while (end < line.length && TERMINATORS.has(line.charAt(end))) end += 1;
      if (end === line.length || isWhitespace(line.charAt(end))) {
        push(line.slice(start, end));
        start = end;
      }
      index = end;
    }
    push(line.slice(start));
  }
  return sentences;
}

/**
 * Grapheme tokenizer: lowercases the sentence, maps each code point through the vocabulary and
 * drops code points the vocabulary lacks.
 */
export class GraphemeTokenizer {
  constructor(private readonly vocab: Record<string, number>) {}

  encode(sentence: string): number[] {
    const ids: number[] = [];
    for (const codePoint of sentence.normalize("NFC").toLowerCase()) {
      const id = this.vocab[codePoint];
      if (id !== undefined) ids.push(id);
    }
    return ids;
  }
}
