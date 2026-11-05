import { describe, expect, it } from "vitest";

import {
  clampDurations,
  encodeLetters,
  equalizeLetterRate,
  isLetter,
  normalizeLetters,
  splitLongSentence,
  toInt16
} from "./math.js";

const CHARSET = " abcdefghijklmnopqrstuvwxyzäöüß.,?!-'\":;()0123456789";

describe("normalizeLetters", () => {
  it("folds accents, maps typography and drops unknown code points", () => {
    expect(normalizeLetters("Café – „Zitat“ … ø 😀", CHARSET)).toBe('cafe - "zitat" . ö');
  });

  it("collapses whitespace and trims", () => {
    expect(normalizeLetters("  a \t\n b  ", CHARSET)).toBe("a b");
  });
});

describe("encodeLetters", () => {
  const config = { charset: CHARSET, languages: { de: 0, en: 1 } };

  it("maps letters to 1 + charset index with one language id per letter", () => {
    const de = encodeLetters("Ich habe Hunger.", "de", config);
    expect(de.ids.slice(0, 4)).toEqual([10, 4, 9, 1]);
    expect(de.languages).toEqual(new Array(de.ids.length).fill(0));
    expect(encodeLetters("Hi", "en", config).languages).toEqual([1, 1]);
  });

  it("is empty for text without letters", () => {
    expect(encodeLetters("123 😀", "de", { ...config, charset: " abc" }).ids).toEqual([]);
  });
});

describe("isLetter", () => {
  it("counts letters and digits, not the placeholder, space or punctuation", () => {
    const { ids } = encodeLetters("a 1.", "de", { charset: CHARSET, languages: { de: 0 } });
    expect([0, ...ids].map((id) => isLetter(id, CHARSET))).toEqual([
      false,
      true,
      false,
      true,
      false
    ]);
  });
});

describe("clampDurations", () => {
  it("clamps, masks and divides by the speed", () => {
    const log = new Float32Array([5, 1000, 2].map((v) => Math.log(v)));
    const d = clampDurations(log, new BigInt64Array([0n, 1n, 1n]), 2, 400);
    expect(Array.from(d)).toEqual([0, 200, 1].map((v) => expect.closeTo(v, 5)));
  });
});

describe("equalizeLetterRate", () => {
  it("rescales only the letters to the target rate", () => {
    const ids = [0, 2, 1, 3, 4];
    const d = new Float32Array([0, 10, 7, 10, 10]);
    equalizeLetterRate(d, ids, CHARSET, 1, 20);
    expect(d[0]).toBe(0);
    expect(d[2]).toBe(7);
    const rate = 3 / ((d[1]! + d[3]! + d[4]!) / 100);
    expect(rate).toBeCloseTo(20, 3);
  });

  it("leaves the durations alone without letters", () => {
    const d = new Float32Array([1]);
    equalizeLetterRate(d, [1], CHARSET, 0, 20);
    expect(Array.from(d)).toEqual([1]);
  });
});

describe("toInt16", () => {
  it("rounds and clips", () => {
    expect(Array.from(toInt16(new Float32Array([0, 0.5, 1.5, -2, -1])))).toEqual([
      0, 16384, 32767, -32767, -32767
    ]);
  });
});

describe("splitLongSentence", () => {
  it("splits after the last comma between the limits", () => {
    const text = `${"a".repeat(119)}, ${"b".repeat(79)}`;
    expect(splitLongSentence(text)).toEqual([`${"a".repeat(119)},`, "b".repeat(79)]);
  });

  it("keeps short text whole and falls back to a space", () => {
    expect(splitLongSentence("kurz.")).toEqual(["kurz."]);
    expect(splitLongSentence(`${"a".repeat(100)} ${"b".repeat(99)}`)).toEqual([
      "a".repeat(100),
      "b".repeat(99)
    ]);
  });

  it("keeps a run without any separator whole", () => {
    expect(splitLongSentence("x".repeat(300))).toEqual(["x".repeat(300)]);
  });
});
