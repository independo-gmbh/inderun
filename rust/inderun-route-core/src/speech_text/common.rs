//! Helpers the language stages share: a callback `replace_all` for `fancy-regex`, capture
//! group access, digit parsing, character-boundary slicing, and the last cleanup of every
//! language's chain ([`tidy`]).

use std::sync::LazyLock;

use fancy_regex::{Captures, Regex};

use super::StageError;

/// Replace every match of `rx` in `text` with what `f` returns for it.
pub(crate) fn replace_all(
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
pub(crate) fn group<'t>(caps: &Captures<'t, str>, index: usize) -> &'t str {
    caps.get(index).map_or("", |m| m.as_str())
}

/// Digits of a pattern's group as a number; a value beyond `u64` fails the line.
pub(crate) fn number(digits: &str) -> Result<u64, StageError> {
    digits.parse().map_err(|_| StageError::Number)
}

/// The last `count` characters of `text` (all of it when shorter), cut on a
/// character boundary.
pub(crate) fn tail_chars(text: &str, count: usize) -> &str {
    match text.char_indices().rev().nth(count.saturating_sub(1)) {
        Some((index, _)) => &text[index..],
        None => text,
    }
}

pub(crate) fn compile(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|error| panic!("invalid pattern {pattern}: {error}"))
}

static SPACE_RUN: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]{2,}"));
static SPACE_BEFORE_PUNCTUATION: LazyLock<Regex> = LazyLock::new(|| compile(r"[ \t]+([,.;:!?])"));

/// The last cleanup: runs of blanks become one space, and there is no space
/// before `, . ; : ! ?`.
pub(crate) fn tidy(text: &str) -> Result<String, StageError> {
    let collapsed = replace_all(&SPACE_RUN, text, |_| Ok(" ".to_string()))?;
    replace_all(&SPACE_BEFORE_PUNCTUATION, &collapsed, |caps| {
        Ok(group(caps, 1).to_string())
    })
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
