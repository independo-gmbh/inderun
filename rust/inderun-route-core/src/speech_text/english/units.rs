//! `expand_units`: `12 km` -> `12 kilometers`, `1 kg` -> `1 kilogram`, `5 km/h` -> `5
//! kilometers per hour`, `8 %` -> `8 percent`. A symbol is a unit only directly after a number.
//! Runs before `numbers`, which then reads the digits the way it reads any other number.

use std::collections::HashMap;
use std::sync::LazyLock;

use fancy_regex::{Captures, Regex};
use serde::Deserialize;

use crate::speech_text::StageError;
use crate::speech_text::common::{compile, group};

/// One row of `data/en/units.json`: singular, plural.
#[derive(Deserialize)]
struct Unit(String, String);

#[derive(Deserialize)]
struct UnitFile {
    units: HashMap<String, Unit>,
}

static UNITS: LazyLock<(HashMap<String, Unit>, Regex)> = LazyLock::new(|| {
    let file: UnitFile = serde_json::from_str(include_str!("../data/en/units.json"))
        .unwrap_or_else(|error| panic!("data/en/units.json: {error}"));
    let mut keys: Vec<&String> = file.units.keys().collect();
    // Longest first, so `km` is tried before `m` and `°C` before `°`.
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
    // Anchored: `expand_units` tries it only where a number may start (see `UNIT_BOUNDARY`), so
    // a long line without units does not spend one backtrack budget on every position.
    let rx = compile(&format!(
        r"^(-?[0-9]+(?:[.,][0-9]+)*(?:[ \t]?[-–][ \t]?[0-9]+(?:[.,][0-9]+)*)?)[ \t]?({alt})(?:/({alt}))?(?![\wÀ-ɏ²³])"
    ));
    (file.units, rx)
});

/// The characters a number must not directly follow: it would be part of a word, of a longer
/// number, or an amount of money (`$5m` is five million dollars, read by `numbers`).
static UNIT_BOUNDARY: LazyLock<Regex> = LazyLock::new(|| compile(r"^[\w.,$€£]$"));

pub(in crate::speech_text) fn expand_units(text: &str) -> Result<String, StageError> {
    if !text.bytes().any(|b| b.is_ascii_digit()) {
        return Ok(text.to_string());
    }
    let (table, rx) = &*UNITS;
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut at = 0;
    while at < text.len() {
        let byte = text.as_bytes()[at];
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
        out.push_str(&spoken(&caps, table));
        last = at + whole.end();
        at = last.max(at + 1);
    }
    out.push_str(&text[last..]);
    Ok(out)
}

/// The number, unchanged, then the unit word: singular after `1` (or `-1`), plural otherwise.
fn spoken(caps: &Captures<'_, str>, table: &HashMap<String, Unit>) -> String {
    let (digits, unit) = (group(caps, 1), group(caps, 2));
    let Some(Unit(singular, plural)) = table.get(unit) else {
        return group(caps, 0).to_string();
    };
    let one = digits.trim_start_matches('-') == "1";
    let word = if one { singular } else { plural };
    match caps.get(3).and_then(|m| table.get(m.as_str())) {
        Some(per) => format!("{digits} {word} per {}", per.0),
        None => format!("{digits} {word}"),
    }
}
