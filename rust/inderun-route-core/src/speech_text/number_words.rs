//! German number words, following the `num2words` German convention the
//! upstream model was trained with: `eins` alone, `ein-` in compounds,
//! `einhundert`, `eintausend`, and separate words from a million upward
//! (`eine Million`, `zwei Millionen`, `eine Milliarde`).

const SMALL: [&str; 20] = [
    "null",
    "eins",
    "zwei",
    "drei",
    "vier",
    "fünf",
    "sechs",
    "sieben",
    "acht",
    "neun",
    "zehn",
    "elf",
    "zwölf",
    "dreizehn",
    "vierzehn",
    "fünfzehn",
    "sechzehn",
    "siebzehn",
    "achtzehn",
    "neunzehn",
];

const TENS: [&str; 10] = [
    "", "", "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig",
];

/// Singular and plural of the scale words from 10^6 upward (all feminine).
const SCALES: [(&str, &str); 5] = [
    ("Million", "Millionen"),
    ("Milliarde", "Milliarden"),
    ("Billion", "Billionen"),
    ("Billiarde", "Billiarden"),
    ("Trillion", "Trillionen"),
];

/// Words for 1..=99. A trailing `eins` becomes `ein` when `compound` is set.
fn below_hundred(n: u64, compound: bool) -> String {
    debug_assert!((1..100).contains(&n));
    if n == 1 && compound {
        return "ein".to_string();
    }
    if n < 20 {
        return SMALL[n as usize].to_string();
    }
    let (tens, ones) = (n / 10, n % 10);
    if ones == 0 {
        return TENS[tens as usize].to_string();
    }
    format!("{}und{}", below_hundred(ones, true), TENS[tens as usize])
}

/// Words for 1..=999, joined into one word.
fn below_thousand(n: u64, compound: bool) -> String {
    debug_assert!((1..1000).contains(&n));
    let (hundreds, rest) = (n / 100, n % 100);
    let mut out = String::new();
    if hundreds > 0 {
        out.push_str(&below_hundred(hundreds, true));
        out.push_str("hundert");
    }
    if rest > 0 {
        out.push_str(&below_hundred(rest, compound));
    } else if hundreds == 0 {
        unreachable!("n is non-zero");
    }
    out
}

/// Words for 1..=999_999, joined into one word.
fn below_million(n: u64) -> String {
    debug_assert!((1..1_000_000).contains(&n));
    let (thousands, rest) = (n / 1000, n % 1000);
    let mut out = String::new();
    if thousands > 0 {
        out.push_str(&below_thousand(thousands, true));
        out.push_str("tausend");
    }
    if rest > 0 {
        out.push_str(&below_thousand(rest, false));
    }
    out
}

/// The cardinal number as German words, e.g. `1250` -> `eintausendzweihundertfünfzig`.
pub(crate) fn cardinal(n: u64) -> String {
    if n == 0 {
        return SMALL[0].to_string();
    }
    let mut parts: Vec<String> = Vec::new();
    let mut m = n / 1_000_000;
    let mut groups = [0u64; SCALES.len()];
    for group in groups.iter_mut() {
        *group = m % 1000;
        m /= 1000;
    }
    for (index, &count) in groups.iter().enumerate().rev() {
        if count == 0 {
            continue;
        }
        let (singular, plural) = SCALES[index];
        if count == 1 {
            parts.push(format!("eine {singular}"));
        } else {
            parts.push(format!("{} {plural}", below_thousand(count, true)));
        }
    }
    let rest = n % 1_000_000;
    if rest > 0 {
        parts.push(below_million(rest));
    }
    parts.join(" ")
}

/// The ordinal as German words with a case ending appended after `te`/`ste`
/// (`""`, `"n"`, `"r"`, `"m"`, `"s"`), e.g. `(3, "n")` -> `dritten`.
pub(crate) fn ordinal(n: u64, ending: &str) -> String {
    format!("{}{ending}", ordinal_stem(n))
}

/// Ordinal word without a case ending. From a million upward it is one
/// lowercase compound (`zweimillionste`, `einmillionerste`).
fn ordinal_stem(n: u64) -> String {
    if n == 0 {
        return "nullte".to_string();
    }
    if n >= 1_000_000 {
        let mut scale = 1_000_000u64;
        let mut index = 0;
        while index + 1 < SCALES.len() && n / scale >= 1000 {
            scale *= 1000;
            index += 1;
        }
        let (count, rest) = (n / scale, n % scale);
        let singular = SCALES[index].0.to_lowercase();
        let prefix = match (count, rest) {
            (1, 0) => String::new(),
            (1, _) => "ein".to_string(),
            _ => below_thousand(count, true),
        };
        let head = format!("{prefix}{singular}");
        return if rest == 0 {
            // `Milliarde` + `ste` drops the stem's final `e`.
            format!("{}ste", head.strip_suffix('e').unwrap_or(&head))
        } else {
            format!("{head}{}", ordinal_stem(rest))
        };
    }
    let low = n % 100;
    let irregular = match low {
        1 => Some("erste"),
        3 => Some("dritte"),
        7 => Some("siebte"),
        8 => Some("achte"),
        _ => None,
    };
    match irregular {
        // The part above the last two digits is a multiple of 100, so its
        // cardinal joins without `und` (or is empty when n is below 100).
        Some(word) if n == low => word.to_string(),
        Some(word) => format!("{}{word}", cardinal(n - low)),
        None if (1..=19).contains(&low) => format!("{}te", cardinal(n)),
        None => format!("{}ste", cardinal(n)),
    }
}

/// A year as spoken German: 1100..=1999 as hundreds (`neunzehnhundertneunzig`),
/// every other number as a plain cardinal.
pub(crate) fn year(n: u64) -> String {
    if (1100..2000).contains(&n) {
        let (hundreds, rest) = (n / 100, n % 100);
        let mut out = format!("{}hundert", cardinal(hundreds));
        if rest > 0 {
            out.push_str(&cardinal(rest));
        }
        out
    } else {
        cardinal(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cardinals() {
        for (n, w) in [
            (0, "null"),
            (1, "eins"),
            (7, "sieben"),
            (11, "elf"),
            (16, "sechzehn"),
            (17, "siebzehn"),
            (21, "einundzwanzig"),
            (30, "dreißig"),
            (70, "siebzig"),
            (100, "einhundert"),
            (101, "einhunderteins"),
            (1000, "eintausend"),
            (1001, "eintausendeins"),
            (1250, "eintausendzweihundertfünfzig"),
            (2026, "zweitausendsechsundzwanzig"),
            (1_000_000, "eine Million"),
            (2_000_000, "zwei Millionen"),
            (1_000_000_000, "eine Milliarde"),
        ] {
            assert_eq!(cardinal(n), w, "{n}");
        }
    }

    #[test]
    fn ordinals() {
        for (n, e, w) in [
            (1, "", "erste"),
            (3, "n", "dritten"),
            (7, "r", "siebter"),
            (8, "", "achte"),
            (20, "m", "zwanzigstem"),
            (21, "", "einundzwanzigste"),
            (31, "n", "einunddreißigsten"),
            (100, "", "einhundertste"),
        ] {
            assert_eq!(ordinal(n, e), w, "{n}{e}");
        }
    }

    #[test]
    fn years() {
        assert_eq!(year(1990), "neunzehnhundertneunzig");
        assert_eq!(year(2026), "zweitausendsechsundzwanzig");
        assert_eq!(year(1100), "elfhundert");
        assert_eq!(year(1101), "elfhunderteins");
        assert_eq!(year(1999), "neunzehnhundertneunundneunzig");
    }

    #[test]
    fn large_and_edge_numbers_do_not_panic() {
        assert_eq!(cardinal(1_000_001), "eine Million eins");
        assert_eq!(cardinal(21_000_000), "einundzwanzig Millionen");
        assert!(!cardinal(u64::MAX).is_empty());
        assert_eq!(ordinal(0, ""), "nullte");
        assert_eq!(ordinal(1000, ""), "eintausendste");
        assert_eq!(ordinal(101, ""), "einhunderterste");
        for (n, e, w) in [
            (1_000_000, "", "millionste"),
            (2_000_000, "", "zweimillionste"),
            (1_000_001, "", "einmillionerste"),
            (3_000_000, "n", "dreimillionsten"),
            (1_000_000_000, "", "milliardste"),
        ] {
            assert_eq!(ordinal(n, e), w, "{n}{e}");
        }
        assert_eq!(ordinal(12, ""), "zwölfte");
        assert_eq!(ordinal(17, ""), "siebzehnte");
    }
}
