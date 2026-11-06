//! `expand_units`: `230 V` -> `230 Volt`, `1 h` -> `eine Stunde`,
//! `50 km/h` -> `50 Kilometer pro Stunde`. Runs before `numbers`, where the
//! `1` would already have become `eins`.

use std::collections::HashMap;
use std::sync::LazyLock;

use fancy_regex::{Captures, Regex};
use serde::Deserialize;

use super::{compile, group, number, replace_all};
use crate::speech_text::StageError;
use crate::speech_text::number_words::cardinal;

/// One row of `units.json`: singular, plural, gender (`m`/`f`/`n`), and whether
/// the unit is only a unit after a space (`16 A`, not `16A`).
#[derive(Deserialize)]
struct Unit(String, String, String, u8);

#[derive(Deserialize)]
struct UnitFile {
    units: HashMap<String, Unit>,
}

static UNITS: LazyLock<(HashMap<String, Unit>, Regex)> = LazyLock::new(|| {
    let file: UnitFile = serde_json::from_str(include_str!("../data/units.json"))
        .unwrap_or_else(|error| panic!("data/units.json: {error}"));
    let mut keys: Vec<&String> = file.units.keys().collect();
    // Longest first, so `km` is tried before `m`; ties are different strings
    // of one length and cannot both match at one place.
    keys.sort_by(|a, b| {
        b.chars()
            .count()
            .cmp(&a.chars().count())
            .then_with(|| a.cmp(b))
    });
    let alt = keys
        .iter()
        .map(|key| fancy_regex::escape(key))
        .collect::<Vec<_>>()
        .join("|");
    // Anchored at the start of the slice `expand_units` hands it, which begins where a number may:
    // the lookbehind `(?<![\w.,])` is checked there on the character before (`UNIT_BOUNDARY`).
    // One scan over the whole line would charge every position it passes to a single backtrack
    // budget, so a long line without a match near its start ran out of it.
    let rx = compile(&format!(
        r"^(-?[0-9]+(?:[.,][0-9]+)*(?:\s?[-–]\s?[0-9]+(?:[.,][0-9]+)*)?)(\s?)({alt})(?:/({alt}))?(?![\wÀ-ɏ²³])"
    ));
    (file.units, rx)
});

/// The characters a number must not directly follow: the lookbehind of the unit pattern.
static UNIT_BOUNDARY: LazyLock<Regex> = LazyLock::new(|| compile(r"^[\w.,]$"));
static CURRENCY_FIRST: LazyLock<Regex> =
    LazyLock::new(|| compile(r"([$€£¥])\s?([0-9]+(?:[.,][0-9]+)*)"));
static LAST_WORD: LazyLock<Regex> = LazyLock::new(|| compile(r"(\w+)\s*$"));

/// "in einer Stunde", "um einen Grad", "ein Meter": the article depends on the
/// case, which the preposition before usually gives away.
const DATIVE: &[&str] = &[
    "in",
    "mit",
    "nach",
    "vor",
    "seit",
    "bei",
    "von",
    "aus",
    "zu",
    "binnen",
    "innerhalb",
    "ab",
    "unter",
];
const ACCUSATIVE: &[&str] = &["für", "durch", "gegen", "ohne", "um", "über", "auf"];

fn article(gender: &str, before: &str) -> Result<&'static str, StageError> {
    // The last word of the whole text before; `\w` is not the same set as
    // `is_alphanumeric` (underscore, marks), so the regex decides.
    let word = match LAST_WORD.captures(before.trim_end())? {
        Some(caps) => group(&caps, 1).to_lowercase(),
        None => String::new(),
    };
    let word = word.as_str();
    Ok(if DATIVE.contains(&word) {
        if gender == "f" { "einer" } else { "einem" }
    } else if ACCUSATIVE.contains(&word) {
        match gender {
            "f" => "eine",
            "m" => "einen",
            _ => "ein",
        }
    } else if gender == "f" {
        "eine"
    } else {
        "ein"
    })
}

/// `"1,80"` as (whole, cents) when it has exactly that shape.
fn metres_and_cents(number_text: &str) -> Option<(&str, &str)> {
    let (whole, cents) = number_text.split_once(',')?;
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    (digits(whole) && digits(cents) && cents.len() == 2).then_some((whole, cents))
}

pub(in crate::speech_text) fn expand_units(text: &str) -> Result<String, StageError> {
    if !text.bytes().any(|b| b.is_ascii_digit()) {
        return Ok(text.to_string());
    }
    let (table, rx) = &*UNITS;
    // $5 -> 5 $
    let text = replace_all(&CURRENCY_FIRST, text, |caps| {
        Ok(format!("{} {}", group(caps, 2), group(caps, 1)))
    })?;
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut at = 0;
    while at < text.len() {
        let byte = text.as_bytes()[at];
        // A match starts at a digit or a sign; any other byte cannot.
        if !(byte.is_ascii_digit() || byte == b'-') {
            at += 1;
            continue;
        }
        let blocked = match text[..at].chars().next_back() {
            Some(previous) => UNIT_BOUNDARY.is_match(previous.encode_utf8(&mut [0; 4]))?,
            None => false,
        };
        let caps = if blocked {
            None
        } else {
            rx.captures(&text[at..])?
        };
        let Some(caps) = caps else {
            at += 1;
            continue;
        };
        let Some(whole) = caps.get(0) else {
            at += 1;
            continue;
        };
        out.push_str(&text[last..at]);
        out.push_str(&expand_match(&caps, &text, at, table)?);
        last = at + whole.end();
        at = last.max(at + 1);
    }
    out.push_str(&text[last..]);
    Ok(out)
}

/// The spoken form of one unit match; `base` is where the match's slice starts in `text`.
fn expand_match(
    caps: &Captures<'_, str>,
    text: &str,
    base: usize,
    table: &HashMap<String, Unit>,
) -> Result<String, StageError> {
    let Some(whole) = caps.get(0) else {
        return Ok(String::new());
    };
    let (whole_start, whole_end) = (base + whole.start(), base + whole.end());
    let (digits, space, unit) = (group(caps, 1), group(caps, 2), group(caps, 3));
    let denominator = caps.get(4).map(|m| m.as_str());
    let Some(Unit(singular, plural, gender, needs_space)) = table.get(unit) else {
        return Ok(whole.as_str().to_string());
    };
    // "16A", "4K-Monitor", "10 T-Shirts": no ampere, kelvin, tesla
    if *needs_space == 1 && space.is_empty() {
        return Ok(whole.as_str().to_string());
    }
    if unit.chars().count() == 1 && text[whole_end..].starts_with('-') {
        return Ok(whole.as_str().to_string());
    }
    let before = &text[..whole_start];
    // Body height and lengths with centimetres: "1,80 m" is "ein Meter achtzig".
    if unit == "m"
        && denominator.is_none()
        && let Some((metres, cents)) = metres_and_cents(digits)
    {
        let (metres, cents) = (number(metres)?, number(cents)?);
        let front = if metres == 1 {
            article("m", before)?.to_string()
        } else {
            cardinal(metres)
        };
        let tail = if cents == 0 {
            String::new()
        } else {
            format!(" {}", cardinal(cents))
        };
        return Ok(format!("{front} Meter{tail}"));
    }
    let one = digits.trim_start_matches('-') == "1";
    let mut word = if one { singular } else { plural }.clone();
    if let Some(denominator) = denominator {
        let per = table.get(denominator).map_or("", |u| u.0.as_str());
        word = format!("{word} pro {per}");
    }
    let lead = if one {
        let sign = if digits.starts_with('-') {
            "minus "
        } else {
            ""
        };
        format!("{sign}{}", article(gender, before)?)
    } else {
        digits.to_string()
    };
    Ok(format!("{lead} {word}"))
}
