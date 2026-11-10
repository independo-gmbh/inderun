//! The English stages of the speech text frontend: original work for IndeRun, not ported (see
//! `../NOTICE`). `contracts/fixtures/speech/english-frontend.json` pins their output, which is
//! US English and serves `en-GB` too.
//!
//! As in the German stages, `\d` is spelled `[0-9]`: the number words are built from ASCII
//! digits.

pub(super) mod abbreviations;
pub(super) mod number_words;
pub(super) mod numbers;
pub(super) mod units;

use std::sync::LazyLock;

use fancy_regex::Regex;

use super::StageError;
use super::common::{self, compile, replace_all};

/// Whether a period right before `rest` ended the sentence: the line ends there, or white
/// space and an upper-case letter follow. `etc.`, `a.m.` and `p.m.` keep their period then.
fn sentence_ends(rest: &str) -> bool {
    let next = rest.trim_start();
    next.is_empty()
        || (next.len() < rest.len() && next.chars().next().is_some_and(char::is_uppercase))
}

/// The symbols an earlier English rule should have spoken. Whatever is left of them becomes a
/// space: the model's tokenizer would drop them without a sound and glue the words around them.
static LEFTOVER_SYMBOL: LazyLock<Regex> = LazyLock::new(|| compile(r"[$€£%&#/°]"));

/// The last English stage: leftover symbols become spaces (`and/or` -> `and or`), then the
/// shared cleanup ([`tidy`](super::common::tidy)) collapses the blanks.
pub(super) fn tidy(text: &str) -> Result<String, StageError> {
    let text = replace_all(&LEFTOVER_SYMBOL, text, |_| Ok(" ".to_string()))?;
    common::tidy(&text)
}
