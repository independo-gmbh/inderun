//! `numbers`: money, times of day, dates, clock times, ordinals, decimals, ranges, signs and
//! plain numbers as English words. The rules run one after the other over the whole line, the
//! forms with a symbol, suffix or separator first and the bare integers last.

use std::sync::LazyLock;

use fancy_regex::Regex;

use super::number_words::{cardinal, digits, ordinal, year};
use super::sentence_ends;
use crate::speech_text::StageError;
use crate::speech_text::common::{compile, group, number, replace_all};

const MONTHS: &str =
    "January|February|March|April|May|June|July|August|September|October|November|December";

/// `1,250` and `3,000,000`: comma groups of three are one number.
static THOUSANDS: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![0-9.,])[0-9]{1,3}(?:,[0-9]{3})+(?![0-9]|,[0-9])"));
/// `$12.50`, `€20`, `£3.99`, and with a scale: `$2.5 billion`, `£5m`, `$3bn`, `$5k` (group 4 is
/// a scale word, group 5 its short form).
static MONEY: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"([$€£])[ \t]?([0-9]+)(?:\.([0-9]+))?(?:[ \t]?(thousand|million|billion|trillion)(?![\wÀ-ɏ])|(bn|k|m)(?![\wÀ-ɏ]))?(?![0-9])",
    )
});
/// `20 €`, `5€`: the euro sign after the amount, as it is often written in Europe.
static TRAILING_EURO: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,$€£])([0-9]+)(?:\.([0-9]+))?[ \t]?€(?![\wÀ-ɏ])"));
/// `1990s`, `'80s`: a decade (group 1 four digits, group 2 two digits after an apostrophe).
static DECADE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?:(?<![\w.,'’])([0-9]{4})|(?<![\w])['’]([0-9]{2}))s(?![\wÀ-ɏ])"));
/// `3/4`, `5/8`, `24/7`; a date such as `11/10/2026` is not one fraction.
static FRACTION: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,/])([0-9]+)/([0-9]+)(?![\w/]|[.,][0-9])"));
/// `#5` and `No. 7` -> `number 5`, `number 7`.
static NUMBER_SIGN: LazyLock<Regex> = LazyLock::new(|| compile(r"(?:#|\bNo\.)[ \t]?(?=[0-9])"));
/// `3 pm`, `3pm`, `9:15 a.m.`, `3 P.M.` -> `3 pee em`, `9:15 ay em`: group 3 is the final period of
/// the dotted form.
static MERIDIEM: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"(?<![\w.,:])([0-9]{1,2}(?::[0-5][0-9])?)[ \t]?(?i:([ap])(?:\.[ \t]?m(\.)?|m))(?![\wÀ-ɏ])",
    )
});
/// `December 24`, `March 4th`, `July 4, 1999`: a day after a full month name, and the year
/// after it.
static DATE: LazyLock<Regex> = LazyLock::new(|| {
    compile(&format!(
        r"\b({MONTHS})[ \t]+([0-9]{{1,2}})(?:st|nd|rd|th)?(?![\w]|[.:][0-9])(?:(,[ \t]*)([0-9]{{4}})(?![\w]|[.,:][0-9]))?"
    ))
});
static CLOCK: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,:])([01]?[0-9]|2[0-4]):([0-5][0-9])(?![0-9]|[:.,][0-9])"));
static ORDINAL: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,])([0-9]+)(?:st|nd|rd|th)(?![\wÀ-ɏ])"));
/// A letter run glued to digits: `B12` -> `B 12`.
static GLUED: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<=\p{L})(?=[0-9])|(?<=[0-9])(?=\p{L})"));
static DECIMAL: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![0-9.,])([0-9]+)\.([0-9]+)(?![0-9]|\.[0-9])"));
/// What `DECIMAL` left between digits is a version or an address: `1.2.3`.
static VERSION_POINT: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<=[0-9])\.(?=[0-9])"));
static RANGE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?<![\w.,–-])([0-9]+)[ \t]?[–-][ \t]?([0-9]+)(?![\w]|[–-][0-9])"));
/// A minus sign after white space or at the start of the line.
static MINUS: LazyLock<Regex> = LazyLock::new(|| compile(r"(?<!\S)-(?=[0-9])"));
static INTEGER: LazyLock<Regex> = LazyLock::new(|| compile(r"[0-9]+"));

/// Twelve digits are the largest number read as a cardinal; longer runs are identifiers.
const LONGEST_CARDINAL: usize = 12;

/// A run of digits: digit by digit when it starts with `0` (and is longer than one digit) or
/// is too long, otherwise a cardinal.
fn integer(run: &str) -> Result<String, StageError> {
    if read_digit_by_digit(run) {
        return Ok(digits(run));
    }
    Ok(cardinal(number(run)?))
}

/// The guard of [`integer`]: an identifier, not a quantity.
fn read_digit_by_digit(run: &str) -> bool {
    (run.len() > 1 && run.starts_with('0')) || run.len() > LONGEST_CARDINAL
}

/// `21st` -> "twenty-first". A run [`integer`] reads digit by digit stays digit by digit, with
/// the last digit as the ordinal: `0123rd` -> "zero one two third".
fn ordinal_of(run: &str) -> Result<String, StageError> {
    if !read_digit_by_digit(run) {
        return Ok(ordinal(number(run)?));
    }
    let (head, last) = run.split_at(run.len() - 1);
    Ok(format!("{} {}", digits(head), ordinal(number(last)?)))
}

/// The last word in its plural: "nineteen ninety" -> "nineteen nineties".
fn plural_of_last_word(words: &str) -> String {
    match words.strip_suffix('y') {
        Some(stem) => format!("{stem}ies"),
        None => format!("{words}s"),
    }
}

/// `1/2` -> "one half", `2/3` -> "two thirds", `3/4` -> "three quarters": words only for the
/// denominators 2, 3 and 4 below one. `24/7` is the fixed expression; anything else is "N over M".
fn fraction(numerator: &str, denominator: &str) -> Result<String, StageError> {
    if (numerator, denominator) == ("24", "7") {
        return Ok("twenty-four seven".to_string());
    }
    let over = || -> Result<String, StageError> {
        Ok(format!(
            "{} over {}",
            integer(numerator)?,
            integer(denominator)?
        ))
    };
    if read_digit_by_digit(numerator) || read_digit_by_digit(denominator) {
        return over();
    }
    let (num, den) = (number(numerator)?, number(denominator)?);
    let name = match den {
        2 => "half",
        3 => "third",
        4 => "quarter",
        _ => return over(),
    };
    if num == 0 || num >= den {
        return over();
    }
    Ok(if num == 1 {
        format!("one {name}")
    } else {
        format!("{} {name}s", cardinal(num))
    })
}

/// The spoken amount: `$12.50` -> "twelve dollars and fifty cents", `$0.50` -> "fifty cents",
/// `$2.5` with the scale `billion` -> "two point five billion dollars". The whole amount goes
/// through [`integer`], so `$0123` is read digit by digit.
fn money(
    symbol: &str,
    whole: &str,
    fraction: Option<&str>,
    scale: Option<&str>,
) -> Result<String, StageError> {
    let (one, many, sub_one, sub_many) = match symbol {
        "$" => ("dollar", "dollars", "cent", "cents"),
        "€" => ("euro", "euros", "cent", "cents"),
        _ => ("pound", "pounds", "pence", "pence"),
    };
    let amount = integer(whole)?;
    if let Some(scale) = scale {
        let point = fraction.map_or(String::new(), |f| format!(" point {}", digits(f)));
        return Ok(format!("{amount}{point} {scale} {many}"));
    }
    let cents = match fraction {
        None => 0,
        Some(two) if two.len() == 2 => number(two)?,
        Some(one_digit) if one_digit.len() == 1 => number(one_digit)? * 10,
        Some(more) => return Ok(format!("{amount} point {} {many}", digits(more))),
    };
    let main = format!("{amount} {}", if whole == "1" { one } else { many });
    if cents == 0 {
        return Ok(main);
    }
    let sub = format!(
        "{} {}",
        cardinal(cents),
        if cents == 1 { sub_one } else { sub_many }
    );
    Ok(if whole.bytes().all(|b| b == b'0') {
        sub
    } else {
        format!("{main} and {sub}")
    })
}

/// The scale word of a money match: a word as written, or the short form spelled out.
fn scale_word(word: Option<&str>, short: Option<&str>) -> Option<&'static str> {
    match word.or(short)? {
        "thousand" | "k" => Some("thousand"),
        "million" | "m" => Some("million"),
        "billion" | "bn" => Some("billion"),
        _ => Some("trillion"),
    }
}

/// `H:MM` -> "H MM": `:00` is silent, `:05` is "oh five".
fn clock(hour: &str, minutes: &str) -> Result<String, StageError> {
    let hour = cardinal(number(hour)?);
    let minutes = number(minutes)?;
    Ok(match minutes {
        0 => hour,
        1..=9 => format!("{hour} oh {}", cardinal(minutes)),
        _ => format!("{hour} {}", cardinal(minutes)),
    })
}

pub(in crate::speech_text) fn numbers(text: &str) -> Result<String, StageError> {
    if !text.bytes().any(|b| b.is_ascii_digit()) {
        return Ok(text.to_string());
    }
    let text = replace_all(&THOUSANDS, text, |c| Ok(group(c, 0).replace(',', "")))?;
    let text = replace_all(&MONEY, &text, |c| {
        let text_of = |index| c.get(index).map(|m| m.as_str());
        money(
            group(c, 1),
            group(c, 2),
            text_of(3),
            scale_word(text_of(4), text_of(5)),
        )
    })?;
    let text = replace_all(&TRAILING_EURO, &text, |c| {
        money("€", group(c, 1), c.get(2).map(|m| m.as_str()), None)
    })?;
    let text = replace_all(&NUMBER_SIGN, &text, |_| Ok("number ".to_string()))?;
    // the year form for four digits, the cardinal for two ("the '80s")
    let text = replace_all(&DECADE, &text, |c| {
        let words = match c.get(1) {
            Some(four) => year(number(four.as_str())?),
            None => cardinal(number(group(c, 2))?),
        };
        Ok(plural_of_last_word(&words))
    })?;
    let text = replace_all(&MERIDIEM, &text, |c| {
        let end = c.get(0).map_or(text.len(), |m| m.end());
        // Spelled the way a voice reads the letters: "a m" and "p m" come out wrong.
        let spoken = if group(c, 2).eq_ignore_ascii_case("a") {
            "ay em"
        } else {
            "pee em"
        };
        // The period of `a.m.` stays only where it was the sentence end too.
        let stop = if c.get(3).is_some() && sentence_ends(&text[end..]) {
            "."
        } else {
            ""
        };
        Ok(format!("{} {spoken}{stop}", group(c, 1)))
    })?;
    let text = replace_all(&DATE, &text, |c| {
        let day = number(group(c, 2))?;
        if !(1..=31).contains(&day) {
            return Ok(group(c, 0).to_string());
        }
        let mut out = format!("{} {}", group(c, 1), ordinal(day));
        if c.get(4).is_some() {
            let digits = group(c, 4);
            let value = number(digits)?;
            out.push_str(group(c, 3));
            if (1000..=2999).contains(&value) {
                out.push_str(&year(value));
            } else {
                out.push_str(digits);
            }
        }
        Ok(out)
    })?;
    let text = replace_all(&CLOCK, &text, |c| clock(group(c, 1), group(c, 2)))?;
    let text = replace_all(&FRACTION, &text, |c| fraction(group(c, 1), group(c, 2)))?;
    let text = replace_all(&ORDINAL, &text, |c| ordinal_of(group(c, 1)))?;
    let text = replace_all(&GLUED, &text, |_| Ok(" ".to_string()))?;
    let text = replace_all(&DECIMAL, &text, |c| {
        Ok(format!(
            "{} point {}",
            integer(group(c, 1))?,
            digits(group(c, 2))
        ))
    })?;
    let text = replace_all(&VERSION_POINT, &text, |_| Ok(" point ".to_string()))?;
    let text = replace_all(&RANGE, &text, |c| {
        Ok(format!("{} to {}", group(c, 1), group(c, 2)))
    })?;
    let text = replace_all(&MINUS, &text, |_| Ok("minus ".to_string()))?;
    replace_all(&INTEGER, &text, |c| integer(group(c, 0)))
}
