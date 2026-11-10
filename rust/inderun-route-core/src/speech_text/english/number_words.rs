//! English number words in US style: `101` is "one hundred one", without "and"; tens and
//! units are joined with a hyphen ("twenty-one").

const ONES: [&str; 20] = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
];

const TENS: [&str; 10] = [
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
];

/// Scale words for each group of three digits, lowest first. Enough for every `u64`.
const SCALES: [&str; 7] = [
    "",
    "thousand",
    "million",
    "billion",
    "trillion",
    "quadrillion",
    "quintillion",
];

/// 0-999 in words; 0 is "zero".
fn below_thousand(n: u64) -> String {
    let index = |value: u64| usize::try_from(value).unwrap_or(0);
    let (hundreds, rest) = (n / 100, n % 100);
    let rest_words = if rest < 20 {
        ONES[index(rest)].to_string()
    } else if rest % 10 == 0 {
        TENS[index(rest / 10)].to_string()
    } else {
        format!("{}-{}", TENS[index(rest / 10)], ONES[index(rest % 10)])
    };
    match (hundreds, rest) {
        (0, _) => rest_words,
        (_, 0) => format!("{} hundred", ONES[index(hundreds)]),
        _ => format!("{} hundred {rest_words}", ONES[index(hundreds)]),
    }
}

/// `n` as a cardinal: "zero", "twenty-one", "one thousand one".
pub(crate) fn cardinal(n: u64) -> String {
    if n == 0 {
        return ONES[0].to_string();
    }
    let mut groups = Vec::new();
    let mut rest = n;
    let mut scale = 0;
    while rest > 0 {
        let group = rest % 1000;
        if group > 0 {
            let words = below_thousand(group);
            groups.push(match SCALES[scale] {
                "" => words,
                name => format!("{words} {name}"),
            });
        }
        rest /= 1000;
        scale += 1;
    }
    groups.reverse();
    groups.join(" ")
}

/// The ordinal form of one cardinal word: "one" -> "first", "twenty" -> "twentieth".
fn ordinal_word(word: &str) -> String {
    match word {
        "one" => "first".to_string(),
        "two" => "second".to_string(),
        "three" => "third".to_string(),
        "five" => "fifth".to_string(),
        "eight" => "eighth".to_string(),
        "nine" => "ninth".to_string(),
        "twelve" => "twelfth".to_string(),
        _ => match word.strip_suffix('y') {
            Some(stem) => format!("{stem}ieth"),
            None => format!("{word}th"),
        },
    }
}

/// `n` as an ordinal: only the last word changes ("twenty-first", "one hundred second").
pub(crate) fn ordinal(n: u64) -> String {
    let words = cardinal(n);
    let cut = words.rfind([' ', '-']).map_or(0, |index| index + 1);
    format!("{}{}", &words[..cut], ordinal_word(&words[cut..]))
}

/// `n` read as a year: "two thousand five", "twenty twenty-six", "nineteen hundred",
/// "nineteen oh five", "nineteen ninety-nine". Outside 1100-2099 it is a cardinal.
pub(crate) fn year(n: u64) -> String {
    match n {
        2000 => cardinal(n),
        2001..=2009 => format!("two thousand {}", cardinal(n - 2000)),
        2010..=2099 => format!("twenty {}", cardinal(n - 2000)),
        1100..=1999 => {
            let (century, rest) = (cardinal(n / 100), n % 100);
            match rest {
                0 => format!("{century} hundred"),
                1..=9 => format!("{century} oh {}", cardinal(rest)),
                _ => format!("{century} {}", cardinal(rest)),
            }
        }
        _ => cardinal(n),
    }
}

/// The ASCII digits of `s`, one word each: "0123" -> "zero one two three". Other characters
/// are skipped.
pub(crate) fn digits(s: &str) -> String {
    s.chars()
        .filter_map(|c| c.to_digit(10))
        .map(|d| ONES[usize::try_from(d).unwrap_or(0)])
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cardinals() {
        for (n, words) in [
            (0, "zero"),
            (15, "fifteen"),
            (40, "forty"),
            (99, "ninety-nine"),
            (100, "one hundred"),
            (110, "one hundred ten"),
            (1_000_000, "one million"),
            (1_002_003, "one million two thousand three"),
            (
                999_999_999_999,
                "nine hundred ninety-nine billion nine hundred ninety-nine million nine hundred ninety-nine thousand nine hundred ninety-nine",
            ),
        ] {
            assert_eq!(cardinal(n), words, "{n}");
        }
        assert!(cardinal(u64::MAX).starts_with("eighteen quintillion"));
    }

    #[test]
    fn ordinals() {
        for (n, words) in [
            (0, "zeroth"),
            (4, "fourth"),
            (9, "ninth"),
            (12, "twelfth"),
            (20, "twentieth"),
            (31, "thirty-first"),
            (100, "one hundredth"),
            (1000, "one thousandth"),
        ] {
            assert_eq!(ordinal(n), words, "{n}");
        }
    }

    #[test]
    fn years() {
        for (n, words) in [
            (1000, "one thousand"),
            (1066, "one thousand sixty-six"),
            (1100, "eleven hundred"),
            (1900, "nineteen hundred"),
            (1905, "nineteen oh five"),
            (1999, "nineteen ninety-nine"),
            (2000, "two thousand"),
            (2009, "two thousand nine"),
            (2010, "twenty ten"),
            (2026, "twenty twenty-six"),
            (2100, "two thousand one hundred"),
        ] {
            assert_eq!(year(n), words, "{n}");
        }
    }

    #[test]
    fn digit_words() {
        assert_eq!(digits("0123"), "zero one two three");
        assert_eq!(digits("4-2"), "four two");
        assert_eq!(digits(""), "");
    }
}
