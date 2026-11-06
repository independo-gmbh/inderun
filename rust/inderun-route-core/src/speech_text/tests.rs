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

#[test]
fn many_dates_on_one_line_stay_fast_and_keep_their_endings() {
    let short = "Der 14. November, 28. November und 5. Dezember, 3. Mai, 4. Mai.";
    assert_eq!(
        normalize_speech_text(short, "de-DE"),
        "Der vierzehnte November, achtundzwanzigste November und fünfte Dezember, dritte Mai, vierte Mai."
    );
    let line: String = (0..300).map(|i| format!("{}. Mai, ", i % 28 + 1)).collect();
    let started = std::time::Instant::now();
    let out = normalize_speech_text(&line, "de-DE");
    assert!(
        started.elapsed().as_secs_f32() < 1.0,
        "{:?}",
        started.elapsed()
    );
    assert!(out.starts_with("erster Mai, zweiter Mai, "), "{out}");
}

#[test]
fn long_and_adversarial_input_is_bounded() {
    let inputs = [
        "1. ".repeat(5000),
        "a".repeat(20000),
        "z. B. ".repeat(3000),
        "AB ".repeat(5000),
        format!("{}AB", " ".repeat(20000)),
        "A".repeat(20000),
        "x ".repeat(8000),
        "z.B.,".repeat(4000) + &" ".repeat(100_000),
    ];
    for input in &inputs {
        let started = std::time::Instant::now();
        let _ = normalize_speech_text(input, "de-DE");
        let elapsed = started.elapsed();
        assert!(
            elapsed.as_secs_f32() < 1.0,
            "{} bytes: {elapsed:?}",
            input.len()
        );
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
    let minutes = "in 5 Minuten 1 ".repeat(3000);
    let cases = [
        ("minutes", minutes.clone()),
        ("ones", "1 ".repeat(2000)),
        (
            "pages",
            "Seite 12 und Kapitel 7, dann 2026 und 42. ".repeat(1000),
        ),
        ("dates", "am 1.1. ".repeat(2000)),
    ];
    for (name, input) in &cases {
        let started = std::time::Instant::now();
        let out = normalize_speech_text(input, "de-DE");
        let elapsed = started.elapsed();
        assert!(&out != input, "{name} stayed unnormalized");
        assert!(elapsed.as_secs_f32() < 1.0, "{name}: {elapsed:?}");
    }
    assert!(normalize_speech_text(&minutes, "de-DE").contains("fünf Minuten"));
}
