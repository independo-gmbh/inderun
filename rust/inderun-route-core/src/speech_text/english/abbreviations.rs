//! `expand_abbreviations`: `e.g.` -> `for example`, `Dr.` -> `Doctor`, `&` -> `and`. The table
//! is `data/en/abbreviations.json`.

use std::collections::HashMap;
use std::sync::LazyLock;

use fancy_regex::Regex;
use serde::Deserialize;

use super::sentence_ends;
use crate::speech_text::StageError;
use crate::speech_text::common::{compile, replace_all};

#[derive(Deserialize)]
struct AbbreviationFile {
    abbreviations: HashMap<String, String>,
}

/// The entries whose period stays when it was also the sentence end. Every other entry always
/// loses its period: `vs. Mrs. Lee` is not three sentences.
const KEEPS_SENTENCE_PERIOD: &[&str] = &["etc."];

struct Rule {
    key: String,
    /// The key with an upper-case first letter (`E.g.`) when the key starts lower-case: matched
    /// only at the start of a sentence, where it is written that way.
    capitalized: Option<String>,
    rx: Regex,
    expansion: String,
    keeps_period: bool,
}

/// `text` with its first letter upper-case.
fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map_or(String::new(), |first| {
        first.to_uppercase().chain(chars).collect()
    })
}

/// Whether `before` (the text up to a match) ends where a sentence starts: nothing but white
/// space, or white space after `.`, `!` or `?`.
fn sentence_starts(before: &str) -> bool {
    let trimmed = before.trim_end();
    trimmed.is_empty() || (trimmed.len() < before.len() && trimmed.ends_with(['.', '!', '?']))
}

static RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    let file: AbbreviationFile =
        serde_json::from_str(include_str!("../data/en/abbreviations.json"))
            .unwrap_or_else(|error| panic!("data/en/abbreviations.json: {error}"));
    let mut pairs: Vec<(String, String)> = file.abbreviations.into_iter().collect();
    // Longest first, ties by key, so the order does not depend on the hash map.
    pairs.sort_by(|(a, _), (b, _)| {
        b.chars()
            .count()
            .cmp(&a.chars().count())
            .then_with(|| a.cmp(b))
    });
    pairs
        .into_iter()
        .map(|(key, expansion)| {
            let capitalized = Some(capitalize(&key)).filter(|upper| *upper != key);
            let pattern = match &capitalized {
                Some(upper) => format!(
                    "(?:{}|{})",
                    fancy_regex::escape(&key),
                    fancy_regex::escape(upper)
                ),
                None => fancy_regex::escape(&key).into_owned(),
            };
            Rule {
                // No letter directly before or after, so `Dr.` does not match inside a word.
                rx: compile(&format!(r"(?<![\wÀ-ɏ]){pattern}(?![\wÀ-ɏ])")),
                keeps_period: KEEPS_SENTENCE_PERIOD.contains(&key.as_str()),
                capitalized,
                key,
                expansion,
            }
        })
        .collect()
});

static AMPERSAND: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]*&[ \t]*"));

pub(in crate::speech_text) fn expand_abbreviations(text: &str) -> Result<String, StageError> {
    let mut text = text.to_string();
    for rule in RULES.iter() {
        let upper = rule.capitalized.as_deref();
        if !text.contains(rule.key.as_str()) && !upper.is_some_and(|u| text.contains(u)) {
            continue;
        }
        let current = text;
        text = replace_all(&rule.rx, &current, |caps| {
            let Some(whole) = caps.get(0) else {
                return Ok(String::new());
            };
            let mut expansion = rule.expansion.clone();
            if upper == Some(whole.as_str()) {
                // `E.g.` inside a sentence is not this abbreviation's sentence-initial form.
                if !sentence_starts(&current[..whole.start()]) {
                    return Ok(whole.as_str().to_string());
                }
                expansion = capitalize(&expansion);
            }
            Ok(
                if rule.keeps_period && sentence_ends(&current[whole.end()..]) {
                    format!("{expansion}.")
                } else {
                    expansion
                },
            )
        })?;
    }
    // `#` before a number was read as "number" already; any other one is not spoken.
    if text.contains('#') {
        text = text.replace('#', "");
    }
    if !text.contains('&') {
        return Ok(text);
    }
    replace_all(&AMPERSAND, &text, |_| Ok(" and ".to_string()))
}
