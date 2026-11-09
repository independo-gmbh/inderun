use super::*;
use serde::Deserialize;
use std::collections::HashSet;

#[test]
fn german_locales() {
    for l in ["de", "de-DE", "DE_at", "de-CH"] {
        assert!(is_german(l), "{l}");
    }
    for l in ["en-US", "", "deu", "d"] {
        assert!(!is_german(l), "{l}");
    }
}

#[test]
fn lines_and_locales_pass_through() {
    assert_eq!(
        normalize_speech_text("Call me at 3.", "en-US"),
        "Call me at 3."
    );
    assert_eq!(normalize_speech_text("Ein\nZwei\n", "de-DE"), "Ein\nZwei\n");
    assert_eq!(normalize_speech_text("", "de-DE"), "");
}

#[derive(Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    id: String,
    locale: String,
    input: String,
    expected: String,
}

#[test]
fn fixture_cases_match() {
    let fixture: Fixture = serde_json::from_str(include_str!(
        "../../../../contracts/fixtures/speech/german-frontend.json"
    ))
    .expect("german-frontend.json parses");
    let mut ids = HashSet::new();
    let mut failures = Vec::new();
    for case in &fixture.cases {
        assert!(ids.insert(case.id.as_str()), "duplicate id {}", case.id);
        let actual = normalize_speech_text(&case.input, &case.locale);
        if actual != case.expected {
            failures.push(format!(
                "{} ({}): {:?}\n    expected {:?}\n    actual   {:?}",
                case.id, case.locale, case.input, case.expected, actual
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} cases differ:\n{}",
        failures.len(),
        fixture.cases.len(),
        failures.join("\n")
    );
}

#[test]
fn never_panics_on_mixed_scripts() {
    let pieces = [
        "Привет",
        "😀",
        "ß",
        "3.",
        "12,50 €",
        "Grüße",
        "14:30",
        "1.250",
        "°C",
        "5 km/h",
        "Am",
        "Mai",
        "ー",
        "٣",
        "-7",
        "3.10.",
        "#4",
        "1/2",
        "x",
        "Jänner",
    ];
    for seed in 0..50usize {
        let text: String = (0..8)
            .map(|k| pieces[(seed * 7 + k * 13 + seed / 3) % pieces.len()])
            .collect::<Vec<_>>()
            .join(if seed % 2 == 0 { " " } else { "" });
        for locale in ["de-DE", "de-AT", "en-US"] {
            let _ = normalize_speech_text(&text, locale);
        }
    }
}

#[test]
fn oversized_numbers_leave_the_line_unchanged() {
    let line = "Es sind 1.000.000.000.000.000.000.000 Euro und 5 Mai.";
    assert_eq!(normalize_speech_text(line, "de-DE"), line);
}

/// Best of three runs after one warm-up, so a scheduler hiccup on a shared CI runner
/// cannot inflate either side of the ratio.
fn best_time(input: &str) -> std::time::Duration {
    let _ = normalize_speech_text(input, "de-DE");
    (0..3)
        .map(|_| {
            let started = std::time::Instant::now();
            let _ = normalize_speech_text(input, "de-DE");
            started.elapsed()
        })
        .min()
        .expect("three runs")
}

/// Asserts that doubling the input does not much more than double the time. An absolute
/// bound flakes with machine speed; a ratio only fails when the algorithm stops scaling
/// (quadratic work would give about 4x). The 10 s ceiling is a backstop, not the check.
fn assert_scales_linearly(name: &str, make: impl Fn(usize) -> String, n: usize) {
    let t1 = best_time(&make(n));
    let t2 = best_time(&make(2 * n));
    assert!(
        t2 < 3 * t1 && t2 < std::time::Duration::from_secs(10),
        "{name}: t(n={n}) = {t1:?}, t(2n) = {t2:?}"
    );
}

#[test]
fn many_dates_on_one_line_stay_fast_and_keep_their_endings() {
    let short = "Der 14. November, 28. November und 5. Dezember, 3. Mai, 4. Mai.";
    assert_eq!(
        normalize_speech_text(short, "de-DE"),
        "Der vierzehnte November, achtundzwanzigste November und fünfte Dezember, dritte Mai, vierte Mai."
    );
    let make = |n: usize| -> String { (0..n).map(|i| format!("{}. Mai, ", i % 28 + 1)).collect() };
    assert_scales_linearly("dates", make, 300);
    let out = normalize_speech_text(&make(300), "de-DE");
    assert!(out.starts_with("erster Mai, zweiter Mai, "), "{out}");
}

#[test]
fn long_and_adversarial_input_is_bounded() {
    type Make = fn(usize) -> String;
    let cases: [(&str, Make, usize); 8] = [
        ("numbered", |n| "1. ".repeat(n), 1500),
        ("letters", |n| "a".repeat(n), 40000),
        ("abbreviations", |n| "z. B. ".repeat(n), 3000),
        ("shouting", |n| "AB ".repeat(n), 10000),
        ("spaces then AB", |n| format!("{}AB", " ".repeat(n)), 80000),
        ("capitals", |n| "A".repeat(n), 40000),
        ("words", |n| "x ".repeat(n), 10000),
        (
            "abbreviation tail",
            |n| "z.B.,".repeat(n) + &" ".repeat(25 * n),
            4000,
        ),
    ];
    for (name, make, n) in cases {
        assert_scales_linearly(name, make, n);
    }
}

#[test]
fn shouting_decides_from_direct_neighbours_only() {
    // a long capitalised neighbour makes the short one a word ...
    assert_eq!(normalize_speech_text("SOFORT KI", "de-DE"), "SOFORT KI");
    assert_eq!(normalize_speech_text("KI SOFORT", "de-DE"), "KI SOFORT");
    // ... punctuation in between, or a lower-case neighbour, does not
    assert_eq!(
        normalize_speech_text("SOFORT, KI", "de-DE"),
        "SOFORT, kah ih"
    );
    assert_eq!(normalize_speech_text("sofort KI", "de-DE"), "sofort kah ih");
}

#[test]
fn eszett_runs_lose_the_eszett_like_upstream() {
    assert_eq!(normalize_speech_text("ßß", "de-DE"), "");
}

#[test]
fn long_benign_lines_are_still_normalized() {
    type Make = fn(usize) -> String;
    let cases: [(&str, Make, usize); 4] = [
        ("minutes", |n| "in 5 Minuten 1 ".repeat(n), 750),
        ("ones", |n| "1 ".repeat(n), 1200),
        (
            "pages",
            |n| "Seite 12 und Kapitel 7, dann 2026 und 42. ".repeat(n),
            250,
        ),
        ("dates", |n| "am 1.1. ".repeat(n), 500),
    ];
    for (name, make, n) in cases {
        let input = make(n);
        let out = normalize_speech_text(&input, "de-DE");
        assert!(out != input, "{name} stayed unnormalized");
        if name == "minutes" {
            assert!(out.contains("fünf Minuten"), "{name}: {out}");
        }
        assert_scales_linearly(name, make, n);
    }
}
