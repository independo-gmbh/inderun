//! The German stages of the speech text frontend: a port of parts of Articulino's
//! `frontend/german.py` (see `../NOTICE`).
//!
//! Each stage keeps upstream's rule order and regular expressions. Python's
//! `re.sub` with a callback has no `fancy-regex` counterpart, so [`replace_all`]
//! walks the matches and copies the text between them. Match offsets are byte
//! offsets on character boundaries, so slicing at them never splits a character.
//!
//! `\d` is spelled `[0-9]` throughout: the number words are built from ASCII
//! digits, and a non-ASCII digit (for example an Arabic-Indic one) stays as it
//! is instead of being half-handled. Likewise `\w` and `\b` are the regex
//! crate's Unicode word set, which is not Python's: superscripts and vulgar
//! fractions are not word characters here, so `10²` becomes `zehn²` and `PC²`
//! becomes `peh zeh²`; combining marks count as word characters here.
//!
//! The lookahead of the weekday range rule spells `\d` as `[0-9]` too.
//! Upstream's `\s*` in an abbreviation key can match a newline; here each line
//! is its own text, so it cannot.

pub(super) mod abbreviations;
pub(super) mod letters;
pub(super) mod numbers;
pub(super) mod units;

use fancy_regex::{Captures, Regex};

use super::StageError;

/// Replace every match of `rx` in `text` with what `f` returns for it.
fn replace_all(
    rx: &Regex,
    text: &str,
    mut f: impl FnMut(&Captures<'_, str>) -> Result<String, StageError>,
) -> Result<String, StageError> {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for caps in rx.captures_iter(text) {
        let caps = caps?;
        let Some(whole) = caps.get(0) else { continue };
        out.push_str(&text[last..whole.start()]);
        out.push_str(&f(&caps)?);
        last = whole.end();
    }
    out.push_str(&text[last..]);
    Ok(out)
}

/// The matched text of group `index`, or `""` when the group did not take part.
fn group<'t>(caps: &Captures<'t, str>, index: usize) -> &'t str {
    caps.get(index).map_or("", |m| m.as_str())
}

/// Digits of a pattern's group as a number; a value beyond `u64` fails the line.
fn number(digits: &str) -> Result<u64, StageError> {
    digits.parse().map_err(|_| StageError::Number)
}

/// The last `count` characters of `text` (all of it when shorter), cut on a
/// character boundary.
fn tail_chars(text: &str, count: usize) -> &str {
    match text.char_indices().rev().nth(count.saturating_sub(1)) {
        Some((index, _)) => &text[index..],
        None => text,
    }
}

fn compile(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|error| panic!("invalid pattern {pattern}: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_chars_cuts_on_character_boundaries() {
        assert_eq!(tail_chars("abc", 5), "abc");
        assert_eq!(tail_chars("abc", 2), "bc");
        assert_eq!(tail_chars("aüß😀", 2), "ß😀");
        assert_eq!(tail_chars("", 3), "");
    }
}
