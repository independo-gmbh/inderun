//! `expand_abbreviations`: `z. B.` -> `zum Beispiel`, `Mo–Fr` -> `Montag bis
//! Freitag`, `%` -> ` Prozent`. The table is `abbreviations.json`, ported
//! unchanged; its rules run one after the other over the whole line.

use std::collections::HashMap;
use std::fmt;
use std::sync::LazyLock;

use fancy_regex::Regex;
use serde::Deserialize;
use serde::de::{MapAccess, Visitor};

use super::{compile, group, replace_all};
use crate::speech_text::StageError;

/// A JSON object read as ordered pairs: rules of equal length keep the file's
/// order, as they do in Python's insertion-ordered dict.
struct Pairs(Vec<(String, String)>);

impl<'de> Deserialize<'de> for Pairs {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct PairsVisitor;
        impl<'de> Visitor<'de> for PairsVisitor {
            type Value = Pairs;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("an object of strings")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Pairs, A::Error> {
                let mut pairs = Vec::new();
                // Duplicate keys are not expected; Python's dict would keep one.
                while let Some(pair) = map.next_entry::<String, String>()? {
                    pairs.push(pair);
                }
                Ok(Pairs(pairs))
            }
        }
        deserializer.deserialize_map(PairsVisitor)
    }
}

#[derive(Deserialize)]
struct AbbreviationFile {
    abbreviations: Pairs,
    symbols: Pairs,
}

enum Replacement {
    /// A table entry without a final period: the text as it is.
    Literal(String),
    /// A table entry ending in a period: the period stays when the sentence
    /// ended there (see [`SENTENCE_START`]).
    KeepPeriod(String),
}

struct Rule {
    /// The text every match starts with (the key up to its first space): a line
    /// without it cannot match, so the pattern is not run on it at all.
    needle: String,
    rx: Regex,
    replacement: Replacement,
}

struct Rules {
    rules: Vec<Rule>,
    /// All-caps table entries (`RAM` -> `Ramm`), also used for plurals (`RAMs`).
    acronyms: HashMap<String, String>,
}

/// Longest key first, otherwise `Mi.` would match before `Mio.` and leave the
/// `o.` behind. Ties keep the order of the file.
fn longest_first(pairs: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut pairs = pairs;
    pairs.sort_by_key(|(key, _)| std::cmp::Reverse(key.chars().count()));
    pairs
}

static RULES: LazyLock<Rules> = LazyLock::new(|| {
    let file: AbbreviationFile = serde_json::from_str(include_str!("../data/abbreviations.json"))
        .unwrap_or_else(|error| panic!("data/abbreviations.json: {error}"));
    let mut rules = Vec::new();
    for (key, value) in longest_first(file.abbreviations.0.clone()) {
        // A space in a key matches any spacing; no letter before and none
        // after, otherwise `Str.` would also match inside a word.
        let pattern = key
            .split(' ')
            .map(fancy_regex::escape)
            .collect::<Vec<_>>()
            .join(r"\s*");
        let rx = compile(&format!(r"(?<![\wÀ-ɏ]){pattern}(?![\wÀ-ɏ])"));
        let replacement = if key.ends_with('.') {
            Replacement::KeepPeriod(value)
        } else {
            Replacement::Literal(value)
        };
        rules.push(Rule {
            needle: key.split(' ').next().unwrap_or_default().to_string(),
            rx,
            replacement,
        });
    }
    for (key, value) in longest_first(file.symbols.0) {
        rules.push(Rule {
            rx: compile(&fancy_regex::escape(&key)),
            needle: key,
            replacement: Replacement::Literal(value),
        });
    }
    let all_caps = compile(r"^[A-ZÄÖÜ]{2,6}$");
    let acronyms = file
        .abbreviations
        .0
        .into_iter()
        .filter(|(key, _)| all_caps.is_match(key).unwrap_or(false))
        .collect();
    Rules { rules, acronyms }
});

/// The spoken form of an all-caps table entry, if `word` is one.
pub(super) fn acronym_word(word: &str) -> Option<&'static str> {
    RULES.acronyms.get(word).map(String::as_str)
}

/// If an abbreviation ends with a period, that period was often also the end
/// of the sentence; written out, the pause would be lost. The period stays if
/// a typical sentence start follows. A capital letter alone is not enough:
/// every German noun starts with one.
static SENTENCE_START: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"^(?:Er|Sie|Es|Der|Die|Das|Den|Dem|Ein|Eine|Einen|Danach|Dann|Später|Damals|Im|In|Am|Auch|Doch|Aber|Wir|Ich|Man|Dies|Diese|Dieser|Dieses|So|Heute|Seit|Bis|Nach|Vor|Als|Wenn|Weil|Hier|Dort|Zudem|Außerdem|Deshalb|Daher|Trotzdem|Jedoch|Allerdings)\b",
    )
});

/// Whether `rest` (the text after an abbreviation) starts with white space and
/// a typical sentence start. Only the first characters after the white space
/// are looked at (the longest start word has ten), so the cost does not grow
/// with the length of the line.
fn sentence_start_follows(rest: &str) -> Result<bool, StageError> {
    let word = rest.trim_start();
    if word.len() == rest.len() {
        return Ok(false);
    }
    let end = word
        .char_indices()
        .nth(12)
        .map_or(word.len(), |(index, _)| index);
    Ok(SENTENCE_START.is_match(&word[..end])?)
}

/// `Mo–Fr` is a range, not two abbreviations with a dash. The period after the
/// second one stays if a sentence follows or ends.
static WEEKDAY_RANGE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(Mo|Di|Mi|Do|Fr|Sa|So)\.?[ \t]*[–-][ \t]*(Mo|Di|Mi|Do|Fr|Sa|So)\b(?:\.(?=[ \t]*[0-9a-zäöüß]))?",
    )
});

fn weekday(abbreviation: &str) -> &'static str {
    match abbreviation {
        "Mo" => "Montag",
        "Di" => "Dienstag",
        "Mi" => "Mittwoch",
        "Do" => "Donnerstag",
        "Fr" => "Freitag",
        "Sa" => "Samstag",
        _ => "Sonntag",
    }
}

static WHITESPACE_RUN: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]{2,}"));

/// Write out abbreviations and symbols from `abbreviations.json`.
pub(in crate::speech_text) fn expand_abbreviations(text: &str) -> Result<String, StageError> {
    if text.is_empty() {
        return Ok(String::new());
    }
    let mut text = replace_all(&WEEKDAY_RANGE, text, |caps| {
        Ok(format!(
            "{} bis {}",
            weekday(group(caps, 1)),
            weekday(group(caps, 2))
        ))
    })?;
    for Rule {
        needle,
        rx,
        replacement,
    } in &RULES.rules
    {
        if !text.contains(needle.as_str()) {
            continue;
        }
        let current = text;
        text = replace_all(rx, &current, |caps| match replacement {
            Replacement::Literal(value) => Ok(value.clone()),
            Replacement::KeepPeriod(value) => {
                let end = caps.get(0).map_or(current.len(), |m| m.end());
                let rest = &current[end..];
                // also at the end of the text: the period was the end of the sentence as well
                let sentence_ends = rest.trim_start().is_empty() || sentence_start_follows(rest)?;
                Ok(if sentence_ends {
                    format!("{value}.")
                } else {
                    value.clone()
                })
            }
        })?;
    }
    replace_all(&WHITESPACE_RUN, &text, |_| Ok(" ".to_string()))
}
