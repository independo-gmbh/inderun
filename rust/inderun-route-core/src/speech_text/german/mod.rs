//! The German stages of the speech text frontend: a port of parts of Articulino's
//! `frontend/german.py` (see `../NOTICE`).
//!
//! Each stage keeps upstream's rule order and regular expressions. Python's
//! `re.sub` with a callback has no `fancy-regex` counterpart, so
//! [`replace_all`](super::common::replace_all) walks the matches and copies the text between
//! them. Match offsets are byte offsets on character boundaries, so slicing at them never
//! splits a character.
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
