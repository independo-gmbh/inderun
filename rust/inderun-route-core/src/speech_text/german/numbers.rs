//! `numbers`: dates, times, money, fractions, ordinals, decimals and plain
//! numbers as German words. The order of the rules matters: first the forms
//! with a period, comma or colon, then the bare integers.

use std::collections::HashMap;
use std::ops::Range;
use std::sync::LazyLock;

use fancy_regex::Regex;

use crate::speech_text::StageError;
use crate::speech_text::common::{compile, group, number, replace_all, tail_chars};
use crate::speech_text::number_words::{cardinal, ordinal, year};

/// Every German locale accepts `Jänner` where upstream accepts `Januar`.
const MONTHS: &str =
    "Januar|Jänner|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember";
const MONTH_NAMES: [&str; 12] = [
    "Januar",
    "Februar",
    "März",
    "April",
    "Mai",
    "Juni",
    "Juli",
    "August",
    "September",
    "Oktober",
    "November",
    "Dezember",
];
const WEEKDAYS: &str = "Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag";

/// After these words "3." is an ordinal, with this ending.
const ORDINAL_TEN: &[&str] = &[
    "am", "im", "vom", "zum", "zur", "beim", "dem", "den", "des", "einem", "einen", "einer",
    "jedem", "jeden",
];
const ORDINAL_TE: &[&str] = &[
    "der", "die", "das", "ins", "ein", "eine", "jede", "jeder", "jedes",
];
const DATE_PREPOSITIONS: &[&str] = &["bis", "ab", "seit", "vor", "nach"];

static ORDINAL: LazyLock<Regex> = LazyLock::new(|| {
    let mut words: Vec<&str> = ORDINAL_TEN.iter().chain(ORDINAL_TE).copied().collect();
    words.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
    compile(&format!(
        r"(?i)\b({})\s+([0-9]{{1,3}})\.(?=[\s,;:!?)\]]|$)",
        words.join("|")
    ))
});
static DATE: LazyLock<Regex> = LazyLock::new(|| {
    compile(&format!(
        r"\b(?:([0-9]{{1,2}})\.\s*(bis|und|oder|[–-])\s*)?([0-9]{{1,2}})\.\s*({MONTHS})\b"
    ))
});
static NUMERIC_DATE: LazyLock<Regex> = LazyLock::new(|| {
    compile(r"(?<![0-9.,])([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4}|[0-9]{2})?(?![0-9])")
});
static DATE_CUE: LazyLock<Regex> = LazyLock::new(|| {
    compile(&format!(
        r"(?i)\b(?:am|vom|zum|bis|ab|seit|den|dem|der|des|vor|nach|zwischen|{WEEKDAYS}|Mo|Di|Mi|Do|Fr|Sa|So)\.?,?\s*$"
    ))
});
/// Enumeration after a date: "der 14. November, 28.11. und 05.12."
static DATE_LIST: LazyLock<Regex> = LazyLock::new(|| {
    compile(&format!(
        r"(?:\b(?:{MONTHS})\b|[0-9]{{1,2}}\.[0-9]{{1,2}}\.)[^.!?0-9]{{0,40}}(?:,|\bund|\boder|\bsowie|\bbis|[–-])\s*$"
    ))
});
/// A date as `DATE` reads it, without the range part; the dates of a line are
/// found once and `date_ending` looks the last one before a position up.
static DATE_SPAN: LazyLock<Regex> =
    LazyLock::new(|| compile(&format!(r"\b[0-9]{{1,2}}\.\s*(?:{MONTHS})\b")));
static APPOSITION: LazyLock<Regex> = LazyLock::new(|| {
    compile(&format!(
        r"(?i)\b(?:am|vom|zum|seit|bis|ab)\s+(?:{WEEKDAYS}),\s*$"
    ))
});
static WORDS: LazyLock<Regex> = LazyLock::new(|| compile(r"[\wÀ-ɏ]+"));
static CLOCK: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b([01]?[0-9]|2[0-4]):([0-5][0-9])\b(?:\s*Uhr\b)?"));
static RATIO: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,:])([0-9]+):([0-9]+)(?![0-9:])"));
/// `12,50 €`, `12.50 €` (a point and exactly two digits, before a currency only), `3,- €`:
/// group 2 is the separator, group 3 the cents (none for the dash). It ends in `(?!\w)`, not
/// `\b`, so a `€` the units stage left as it is (`3,- €`) still ends the match.
static MONEY: LazyLock<Regex> = LazyLock::new(|| {
    compile(r"\b([0-9]+)(?:([.,])([0-9]{2})|,[-–])\s*(€|Euro|US-Dollar|Dollar|Pfund|Franken)(?!\w)")
});
/// A point or comma right before the amount: `192.168.1.50 Euro` is no amount.
static AFTER_SEPARATED_DIGITS: LazyLock<Regex> = LazyLock::new(|| compile(r"[0-9][.,]$"));
static TIMES: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<=[0-9])\s?[x×]\s?(?=[0-9])"));
static FRACTION: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,/])([0-9]{1,2})/([0-9]{1,2})(?![\w/])"));
static ONE_UHR: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<![\w.,])1(?=\s+Uhr\b)"));
static ONE_MILLION: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,])1(?=\s+(?:Million|Milliarde|Billion)\b)"));
static THOUSANDS: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![0-9]\.)\b[0-9]{1,3}(?:\.[0-9]{3})+\b(?!\.[0-9])"));
static THOUSANDS_DECIMAL: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![0-9.])([0-9]{1,3}(?:\.[0-9]{3})+)(?=,[0-9])"));
static NUMBER_SIGN: LazyLock<Regex> = LazyLock::new(|| compile(r"#[ \t]?([0-9]+)\b"));
static DECIMAL: LazyLock<Regex> = LazyLock::new(|| compile(r"\b([0-9]+),([0-9]+)\b"));
static VERSION_POINT: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<=[0-9])\.(?=[0-9])"));
static RANGE: LazyLock<Regex> = LazyLock::new(|| compile(r"\b([0-9]+)\s?[–-]\s?([0-9]+)\b"));
static MINUS: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<!\w)-(?=[0-9])"));
static GLUED: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<=[A-Za-zÄÖÜäöüß])(?=[0-9])|(?<=[0-9])(?=[A-Za-zÄÖÜäöüß])"));
static INTEGER: LazyLock<Regex> = LazyLock::new(|| compile(r"\b[0-9]+\b"));

/// Written-out ordinals 1-31 with their ending, for enumerations.
static ORDINAL_WORDS: LazyLock<HashMap<String, &'static str>> = LazyLock::new(|| {
    let mut words = HashMap::new();
    for n in 1..=31 {
        for ending in ["", "n", "r", "m"] {
            words.insert(ordinal(n, ending), ending);
        }
    }
    words
});
static MONTHS_LOWER: LazyLock<Vec<String>> =
    LazyLock::new(|| MONTHS.split('|').map(str::to_lowercase).collect());

/// `de-AT` (any separator, any case) writes month 1 as `Jänner`.
fn is_austrian(locale: &str) -> bool {
    locale
        .split(['-', '_'])
        .skip(1)
        .any(|subtag| subtag.eq_ignore_ascii_case("at"))
}

fn is_month(word: &str) -> bool {
    MONTHS_LOWER.iter().any(|month| month == word)
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first
            .to_uppercase()
            .chain(chars.flat_map(char::to_lowercase))
            .collect(),
        None => String::new(),
    }
}

fn cardinal_of(digits: &str) -> Result<String, StageError> {
    Ok(cardinal(number(digits)?))
}

/// "ein" for 1, else the cardinal.
fn ein_or_cardinal(n: u64) -> String {
    if n == 1 {
        "ein".to_string()
    } else {
        cardinal(n)
    }
}

fn digit_words(digits: &str) -> String {
    digits
        .chars()
        .filter_map(|c| c.to_digit(10))
        .map(|d| cardinal(u64::from(d)))
        .collect::<Vec<_>>()
        .join(" ")
}

fn fraction(num: u64, den: u64) -> Option<String> {
    if !(0 < num && num < den && den <= 10) {
        return None;
    }
    let name = if den == 2 {
        "halb".to_string()
    } else {
        format!("{}l", capitalize(&ordinal(den, "")))
    };
    Some(format!("{} {name}", ein_or_cardinal(num)))
}

/// Ending of the ordinal in a date, read from the word before: "am 25. Juli"
/// -> fünfundzwanzigsten, "der 25. Juli" -> fünfundzwanzigste, without an
/// article ("Berlin, 25. Juli 2000") -> fünfundzwanzigster.
fn date_ending(
    text: &str,
    start: usize,
    dates: &[Range<usize>],
    known: &mut HashMap<usize, &'static str>,
) -> Result<&'static str, StageError> {
    // Every position passed on the way back to an earlier date has the same
    // ending as the position it started from; remembering them keeps a line of
    // many dates linear instead of walking the whole chain for every date.
    let mut visited = Vec::new();
    let mut end = start;
    let ending = loop {
        if let Some(&ending) = known.get(&end) {
            break ending;
        }
        visited.push(end);
        match date_ending_step(&text[..end], dates)? {
            Ending::Done(ending) => break ending,
            Ending::EarlierDate(position) => end = position,
        }
    };
    known.extend(visited.into_iter().map(|position| (position, ending)));
    Ok(ending)
}

enum Ending {
    Done(&'static str),
    /// Read the ending from the text before the date that starts here.
    EarlierDate(usize),
}

fn date_ending_step(before: &str, dates: &[Range<usize>]) -> Result<Ending, StageError> {
    use Ending::Done;
    let lowered = tail_chars(before, 80).to_lowercase();
    let mut words = Vec::new();
    for found in WORDS.find_iter(&lowered) {
        words.push(found?.as_str());
    }
    let count = words.len();
    let word = words.last().copied().unwrap_or("");
    // apposition: "am Freitag, 25. Juli" - the case comes from "am"
    if APPOSITION.is_match(before)? {
        return Ok(Done("n"));
    }
    // "am dritten und 4. Mai", "der dritte bis 5. Mai": like the number before
    if matches!(word, "und" | "oder" | "bis") && count > 1 {
        let previous = words[count - 2];
        if !previous.chars().all(|c| c.is_ascii_digit()) {
            for (suffix, ending) in [("ten", "n"), ("ter", "r"), ("te", "")] {
                if previous.ends_with(suffix) {
                    return Ok(Done(ending));
                }
            }
        }
    }
    // "der 14. November, 28. November und 5. Dezember": like the date before
    let back = if is_month(word) {
        Some(1)
    } else if matches!(word, "und" | "oder" | "sowie" | "bis")
        && count > 1
        && is_month(words[count - 2])
    {
        Some(2)
    } else {
        None
    };
    if let Some(back) = back {
        // already written out ("vierzehnte November, 28. November") or still digits
        if count > back
            && let Some(ending) = ORDINAL_WORDS.get(words[count - 1 - back])
        {
            return Ok(Done(ending));
        }
        // the last date before this position (dates never overlap)
        let upto = dates.partition_point(|date| date.end <= before.len());
        if let Some(previous) = upto.checked_sub(1).map(|index| &dates[index]) {
            return Ok(Ending::EarlierDate(previous.start));
        }
    }
    if word == "zwischen" {
        return Ok(Done("m")); // zwischen achtundzwanzigstem November
    }
    // "am ersten, 2. und 3. Mai": like the ordinal already written out before
    if let Some(ending) = ORDINAL_WORDS.get(word) {
        return Ok(Done(ending));
    }
    if ORDINAL_TEN.contains(&word) || DATE_PREPOSITIONS.contains(&word) {
        return Ok(Done("n"));
    }
    if ORDINAL_TE.contains(&word) {
        return Ok(Done(""));
    }
    Ok(Done("r"))
}

fn integer(digits: &str) -> Result<String, StageError> {
    if (digits.len() > 1 && digits.starts_with('0')) || digits.len() > 9 {
        return Ok(digit_words(digits)); // phone numbers, identifiers
    }
    let n = number(digits)?;
    if digits.len() == 4 && (1100..=1999).contains(&n) {
        return Ok(year(n)); // neunzehnhundertneunzig
    }
    Ok(cardinal(n))
}

pub(in crate::speech_text) fn numbers(text: &str, locale: &str) -> Result<String, StageError> {
    if !text.bytes().any(|b| b.is_ascii_digit()) {
        return Ok(text.to_string());
    }
    let january = if is_austrian(locale) {
        "Jänner"
    } else {
        "Januar"
    };
    let month_name = |month: u64| match month {
        1 => january,
        _ => MONTH_NAMES[usize::try_from(month).unwrap_or(1) - 1],
    };

    let text = replace_all(&THOUSANDS_DECIMAL, text, |c| {
        Ok(group(c, 1).replace('.', ""))
    })?;
    let text = replace_all(&NUMBER_SIGN, &text, |c| {
        Ok(format!("Nummer {}", group(c, 1)))
    })?;

    // "29.09.2026", "3.10." -> "29. September 2026", "3. Oktober"; ORDINAL and
    // DATE set the ending afterwards.
    let text = replace_all(&NUMERIC_DATE, &text, |c| {
        let whole = c.get(0).map_or(0..0, |m| m.range());
        let (day, month, year) = (number(group(c, 1))?, number(group(c, 2))?, group(c, 3));
        if !((1..=31).contains(&day) && (1..=12).contains(&month)) {
            return Ok(group(c, 0).to_string());
        }
        // Without a year only with a hint at a date: a date word before, an
        // enumeration after a date, or the two-digit form "28.11." ("Python 3.12." stays).
        let before = &text[..whole.start];
        let two_digit = group(c, 1).len() == 2 && group(c, 2).len() == 2;
        if year.is_empty()
            && !(two_digit || DATE_CUE.is_match(before)? || DATE_LIST.is_match(before)?)
        {
            return Ok(group(c, 0).to_string());
        }
        let mut out = format!("{day}. {}", month_name(month));
        if !year.is_empty() {
            out.push(' ');
            out.push_str(year);
        } else if whole.end == text.len() {
            // The period was the sentence end too. "End of text" is the end of
            // the line: lines are normalized independently on purpose (design
            // ruling 4), so a line break counts as an end here as well.
            out.push('.');
        }
        Ok(out)
    })?;

    // "am 3." -> "am dritten". At the end of the text the period was the sentence end as well.
    let text = replace_all(&ORDINAL, &text, |c| {
        let end = c.get(0).map_or(0, |m| m.end());
        let article = group(c, 1);
        let ending = if ORDINAL_TEN.contains(&article.to_lowercase().as_str()) {
            "n"
        } else {
            ""
        };
        // Kept per line on purpose, as above (design ruling 4).
        let stop = if end == text.len() { "." } else { "" };
        Ok(format!(
            "{article} {}{stop}",
            ordinal(number(group(c, 2))?, ending)
        ))
    })?;

    let mut dates = Vec::new();
    for found in DATE_SPAN.find_iter(&text) {
        dates.push(found?.range());
    }
    let mut known = HashMap::new();
    let text = replace_all(&DATE, &text, |c| {
        let start = c.get(0).map_or(0, |m| m.start());
        let ending = date_ending(&text, start, &dates, &mut known)?;
        let day = format!("{} {}", ordinal(number(group(c, 3))?, ending), group(c, 4));
        if c.get(1).is_some() {
            let between = match group(c, 2) {
                "–" | "-" => "bis",
                other => other,
            };
            return Ok(format!(
                "{} {between} {day}",
                ordinal(number(group(c, 1))?, ending)
            ));
        }
        Ok(day)
    })?;

    let text = replace_all(&CLOCK, &text, |c| {
        let mut out = format!("{} Uhr", ein_or_cardinal(number(group(c, 1))?));
        if group(c, 2) != "00" {
            out.push(' ');
            out.push_str(&cardinal_of(group(c, 2))?);
        }
        Ok(out)
    })?;
    // what CLOCK did not take as a time is a ratio or a score
    let text = replace_all(&RATIO, &text, |c| {
        Ok(format!("{} zu {}", group(c, 1), group(c, 2)))
    })?;
    let text = replace_all(&MONEY, &text, |c| {
        let start = c.get(0).map_or(0, |m| m.start());
        if group(c, 2) == "." && AFTER_SEPARATED_DIGITS.is_match(&text[..start])? {
            return Ok(group(c, 0).to_string());
        }
        let currency = if group(c, 4) == "€" {
            "Euro"
        } else {
            group(c, 4)
        };
        let cents = c.get(3).map(|m| m.as_str()).filter(|cents| *cents != "00");
        // "0,99 €" -> "neunundneunzig Cent"; Pfund and Franken have other subunits and keep
        // "null Pfund neunundneunzig".
        if let Some(cents) = cents
            && number(group(c, 1))? == 0
            && matches!(currency, "Euro" | "Dollar" | "US-Dollar")
        {
            let cents = if number(cents)? == 1 {
                "ein".to_string()
            } else {
                cardinal_of(cents)?
            };
            return Ok(format!("{cents} Cent"));
        }
        let euros = if group(c, 1) == "1" {
            "ein".to_string()
        } else {
            cardinal_of(group(c, 1))?
        };
        let mut out = format!("{euros} {currency}");
        if let Some(cents) = cents {
            out.push(' ');
            out.push_str(&cardinal_of(cents)?);
        }
        Ok(out)
    })?;
    let text = replace_all(&TIMES, &text, |_| Ok(" mal ".to_string()))?; // 2 x 3 m
    // 3/4 -> drei Viertel
    let text = replace_all(&FRACTION, &text, |c| {
        let (num, den) = (number(group(c, 1))?, number(group(c, 2))?);
        Ok(fraction(num, den).unwrap_or_else(|| group(c, 0).to_string()))
    })?;
    let text = replace_all(&ONE_UHR, &text, |_| Ok("ein".to_string()))?;
    let text = replace_all(&ONE_MILLION, &text, |_| Ok("eine".to_string()))?;
    let text = replace_all(&THOUSANDS, &text, |c| {
        cardinal_of(&group(c, 0).replace('.', ""))
    })?;
    // "Komma," with a short pause: without it the model swallowed it before "fünf"/"vier"
    let text = replace_all(&DECIMAL, &text, |c| {
        Ok(format!(
            "{} Komma, {}",
            integer(group(c, 1))?,
            digit_words(group(c, 2))
        ))
    })?;
    // a period between digits now is a version, IP or decimal: "zwei Punkt fünf"
    let text = replace_all(&VERSION_POINT, &text, |_| Ok(" Punkt ".to_string()))?;
    let text = replace_all(&RANGE, &text, |c| {
        Ok(format!("{} bis {}", group(c, 1), group(c, 2)))
    })?;
    let text = replace_all(&MINUS, &text, |_| Ok("minus ".to_string()))?;
    let text = replace_all(&GLUED, &text, |_| Ok(" ".to_string()))?;
    replace_all(&INTEGER, &text, |c| integer(group(c, 0)))
}
