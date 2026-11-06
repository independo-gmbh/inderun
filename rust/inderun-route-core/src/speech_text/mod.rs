//! Spoken-form normalization of text before speech synthesis.
//!
//! [`normalize_speech_text`] is the single entry point. It never fails: a
//! non-German locale returns the input unchanged, and a stage that errors
//! leaves its line unchanged (all-or-nothing per line). Lines are split on
//! `\n` and normalized independently, so the line structure is preserved.

mod german;
mod number_words;

/// A stage failed on a line: a `fancy-regex` error (for example a backtrack
/// limit), or a run of digits too long for the number words.
#[derive(Debug)]
pub(crate) enum StageError {
    Regex(#[allow(dead_code)] fancy_regex::Error),
    Number,
}

impl From<fancy_regex::Error> for StageError {
    fn from(error: fancy_regex::Error) -> Self {
        Self::Regex(error)
    }
}

/// One normalization step over a single line; the second argument is the locale.
pub(crate) type Stage = fn(&str, &str) -> Result<String, StageError>;

/// The German stages, applied in order to every line.
const STAGES: &[Stage] = &[
    units_stage,
    numbers_stage,
    abbreviations_stage,
    spelling_stage,
    tidy_stage,
];

fn units_stage(text: &str, _locale: &str) -> Result<String, StageError> {
    german::units::expand_units(text)
}

fn numbers_stage(text: &str, locale: &str) -> Result<String, StageError> {
    german::numbers::numbers(text, locale)
}

fn abbreviations_stage(text: &str, _locale: &str) -> Result<String, StageError> {
    german::abbreviations::expand_abbreviations(text)
}

fn spelling_stage(text: &str, _locale: &str) -> Result<String, StageError> {
    german::letters::spell_out_letters(text)
}

fn tidy_stage(text: &str, _locale: &str) -> Result<String, StageError> {
    german::letters::tidy(text)
}

/// True when the language subtag of `locale` is `de` (case-insensitive,
/// `-` or `_` separated): `de`, `de-DE`, `DE_at`.
pub(crate) fn is_german(locale: &str) -> bool {
    locale
        .split(['-', '_'])
        .next()
        .is_some_and(|language| language.eq_ignore_ascii_case("de"))
}

fn normalize_line(line: &str, locale: &str) -> String {
    let mut current = line.to_string();
    for stage in STAGES {
        match stage(&current, locale) {
            Ok(next) => current = next,
            Err(_) => return line.to_string(),
        }
    }
    current
}

/// Rewrite `text` into the form a German speech model expects (digits,
/// abbreviations and units as words). Non-German locales are returned unchanged.
pub fn normalize_speech_text(text: &str, locale: &str) -> String {
    if !is_german(locale) {
        return text.to_string();
    }
    text.split('\n')
        .map(|line| normalize_line(line, locale))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests;
