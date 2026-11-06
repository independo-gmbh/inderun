//! `spell_out_letters`: upper-case abbreviations, single letters and
//! vowel-less runs become German letter names (`PDF` -> `peh deh eff`), and
//! `tidy`, the last cleanup of the whole chain.
//!
//! The model reads letter by letter after lower-casing: "PDF" becomes the
//! made-up word "pdf", "KI" becomes "key". Abbreviations spoken as a word
//! (NASA, PIN) are in `abbreviations.json` and replaced before. Real words in
//! capitals (NICHT) stay: the model reads them correctly after lower-casing.

use std::sync::LazyLock;

use fancy_regex::Regex;

use super::abbreviations::acronym_word;
use super::{compile, group, replace_all};
use crate::speech_text::StageError;

fn letter_name(letter: char) -> Option<&'static str> {
    Some(match letter {
        'A' => "ah",
        'B' => "beh",
        'C' => "zeh",
        'D' => "deh",
        'E' => "eh",
        'F' => "eff",
        'G' => "geh",
        'H' => "hah",
        'I' => "ih",
        'J' => "jott",
        'K' => "kah",
        'L' => "ell",
        'M' => "emm",
        'N' => "enn",
        'O' => "oh",
        'P' => "peh",
        'Q' => "kuh",
        'R' => "err",
        'S' => "ess",
        'T' => "teh",
        'U' => "uh",
        'V' => "fau",
        'W' => "weh",
        'X' => "iks",
        'Y' => "üpsilon",
        'Z' => "zett",
        'Ä' => "äh",
        'Ö' => "öh",
        'Ü' => "üh",
        _ => return None,
    })
}

/// Short German words written in capitals ("DAS IST GUT"): not spelled out.
const SHORT_WORDS: &[&str] = &[
    "AB", "AN", "AM", "AUF", "AUS", "BEI", "BIS", "DA", "DAS", "DEM", "DEN", "DER", "DES", "DIE",
    "DU", "EIN", "ER", "ES", "FÜR", "GUT", "HER", "HIN", "ICH", "IHR", "IM", "IN", "IST", "JA",
    "JE", "MAL", "MIT", "NEU", "NIE", "NUN", "NUR", "OB", "OFT", "SIE", "SO", "TAG", "UM", "UND",
    "UNS", "VOM", "VON", "VOR", "WAS", "WER", "WIE", "WIR", "WO", "ZU", "ZUM", "ZUR", "ALT",
    "NEIN", "DOCH", "NOCH", "SEHR", "HIER", "JETZT", "BITTE", "DANKE", "ALLE", "ODER", "ABER",
    "AUCH",
];

/// Longer abbreviations with a vowel that are spelled out anyway (otherwise:
/// 4+ letters with a vowel = a word).
const ALWAYS_SPELLED: &[&str] = &[
    "ADAC", "DSGVO", "ISBN", "SUV", "DFB", "HTTPS", "VPN", "UKW", "IHK", "AOK", "ABS", "GPS",
    "USB", "FAQ", "EDV", "OECD", "UNHCR", "WHO", "AGB", "BGB", "STVO", "IOS", "USA", "EU", "ARD",
    "CDU", "CSU", "SPD", "FDP", "AFD", "ICE", "IC", "DB", "ÖPNV", "HIV",
];

const INTERJECTIONS: &[&str] = &[
    "hm", "hmm", "pst", "psst", "brr", "grr", "pff", "pfff", "tss", "sch", "st", "ts", "pscht",
];

const VOWELS: &str = "AEIOUÄÖÜY";

/// Upper-case runs; `s` is a plural ending.
static UPPERCASE_ABBR: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\wÀ-ɏ])([A-ZÄÖÜ]{2,6})(s?)(?![\wÀ-ɏ])"));
/// Lower-case runs without a vowel (paths, short forms: "srv", "mnt").
static NO_VOWEL: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\wÀ-ɏ'’-])([bcdfghjklmnpqrstvwxzß]{2,5})(?![\wÀ-ɏ'’-])"));
/// Single letters (formulas, "Plan B") are spoken by their names. Not:
/// hyphenated words (U-Bahn, E-Mail, x-mal) and the English "I".
static SINGLE_LETTER: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\wÀ-ɏ'’.-])([a-zA-ZäöüÄÖÜ])(?![\wÀ-ɏ'’-]|\.[a-zA-Z])"));
static ROMAN: LazyLock<Regex> = LazyLock::new(|| compile(r"^[IVX]+$"));

fn is_letter_run_char(c: char) -> bool {
    c.is_ascii_alphabetic() || "ÄÖÜäöüß".contains(c)
}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// The word of letters directly before `end` with only spaces and tabs
/// (at least one) in between; `None` when there is none.
fn word_before(text: &str, end: usize) -> Option<&str> {
    let head = text[..end].trim_end_matches(is_blank);
    if head.len() == end {
        return None;
    }
    let word = head.trim_end_matches(is_letter_run_char);
    let word = &head[word.len()..];
    (!word.is_empty()).then_some(word)
}

/// The word of letters directly after `start` with only spaces and tabs
/// (at least one) in between; `None` when there is none.
fn word_after(text: &str, start: usize) -> Option<&str> {
    let tail = text[start..].trim_start_matches(is_blank);
    if tail.len() == text.len() - start {
        return None;
    }
    let len = tail
        .find(|c: char| !is_letter_run_char(c))
        .unwrap_or(tail.len());
    (len > 0).then_some(&tail[..len])
}

fn has_vowel(word: &str) -> bool {
    word.chars().any(|c| VOWELS.contains(c))
}

/// A neighbour word also in capitals ("BITTE SOFORT MELDEN") means these are
/// words, but only if one of them is a long word with a vowel. Only direct
/// neighbours without punctuation in between. The neighbours are found next
/// to the match instead of searching the whole text, which would make a long
/// line quadratic.
fn shouting(text: &str, start: usize, end: usize, word: &str) -> bool {
    let neighbours: Vec<&str> = [word_before(text, start), word_after(text, end)]
        .into_iter()
        .flatten()
        .filter(|x| x.chars().all(char::is_uppercase) && x.chars().count() >= 2)
        .collect();
    !neighbours.is_empty()
        && neighbours
            .iter()
            .chain(std::iter::once(&word))
            .any(|x| x.chars().count() >= 4 && has_vowel(x))
}

fn spelled(word: &str, plural: &str) -> String {
    let names: Vec<&str> = word.chars().filter_map(letter_name).collect();
    format!("{}{plural}", names.join(" "))
}

/// Python's `c.upper()` as a letter name: `ß` upper-cases to `SS`, which has no
/// name, so it is dropped.
fn upper_letter_name(c: char) -> Option<&'static str> {
    let mut upper = c.to_uppercase();
    match (upper.next(), upper.next()) {
        (Some(single), None) => letter_name(single),
        _ => None,
    }
}

pub(in crate::speech_text) fn spell_out_letters(text: &str) -> Result<String, StageError> {
    if text.is_empty() {
        return Ok(String::new());
    }
    let step1 = replace_all(&UPPERCASE_ABBR, text, |caps| {
        let whole = caps.get(0).expect("group 0 always matches");
        let (word, plural) = (group(caps, 1), group(caps, 2));
        if SHORT_WORDS.contains(&word) || ROMAN.is_match(word)? {
            return Ok(whole.as_str().to_string());
        }
        if let Some(spoken) = acronym_word(word) {
            return Ok(format!("{spoken}{plural}"));
        }
        if ALWAYS_SPELLED.contains(&word) || !has_vowel(word) {
            return Ok(spelled(word, plural));
        }
        if shouting(text, whole.start(), whole.end(), word) {
            return Ok(whole.as_str().to_string());
        }
        if word.chars().count() <= 3 {
            return Ok(spelled(word, plural));
        }
        Ok(whole.as_str().to_string()) // 4+ letters with a vowel: a word (NICHT)
    })?;
    let step2 = replace_all(&NO_VOWEL, &step1, |caps| {
        let word = group(caps, 1);
        if INTERJECTIONS.contains(&word) {
            return Ok(word.to_string());
        }
        let names: Vec<&str> = word.chars().filter_map(upper_letter_name).collect();
        Ok(names.join(" "))
    })?;
    replace_all(&SINGLE_LETTER, &step2, |caps| {
        let letter = group(caps, 1);
        if letter == "I" {
            return Ok(letter.to_string());
        }
        let upper = letter.chars().next().and_then(upper_letter_name);
        Ok(upper.unwrap_or(letter).to_string())
    })
}

static SPACE_RUN: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]{2,}"));
static SPACE_BEFORE_PUNCTUATION: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]+([,.;:!?])"));

/// The last cleanup: runs of blanks become one space, and there is no space
/// before `, . ; : ! ?`.
pub(in crate::speech_text) fn tidy(text: &str) -> Result<String, StageError> {
    let collapsed = replace_all(&SPACE_RUN, text, |_| Ok(" ".to_string()))?;
    replace_all(&SPACE_BEFORE_PUNCTUATION, &collapsed, |caps| {
        Ok(group(caps, 1).to_string())
    })
}
