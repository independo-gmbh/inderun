# German Text Frontend (PR 4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** German request text is written out (numbers, dates, times, money, units, abbreviations, acronyms) by one
Rust implementation in the route core before the neural speech provider splits it into sentences, on Web, Apple and
Android.

**Architecture:** A `speech_text` module in `rust/inderun-route-core` ports the in-scope stages of upstream
Articulino's `frontend/german.py` (Apache-2.0) with `fancy-regex` and its own German number words. Each existing
binding (C for the committed XCFramework, JNI for Android, wasm-bindgen for the Web) gains one entry point. The neural
speech runtime seam gains an optional pre-split hook `normalizeText`, which the Articulino runtimes implement by
calling that entry point; the provider calls the hook on the whole text before `splitSentences`.

**Tech Stack:** Rust 2024 (`fancy-regex`, `serde_json`), wasm-bindgen, C FFI + XCFramework, JNI; TypeScript/Vitest,
Swift/XCTest, Kotlin/JUnit + Robolectric.

**Spec:** `docs/superpowers/specs/2026-11-05-german-frontend-design.md` (read it in full, including "Settled after the
builder check"). Upstream source being ported (read only, never execute):
`/private/tmp/claude-501/-Users-konstantin-IdeaProjects-inderun/5a55f4df-cb03-40bb-92de-8cd34af009d0/scratchpad/articulino/src/frontend/german.py`
and its `data/abbreviations.json`, `data/units.json`; NOTICE in `.../articulino/onnx/NOTICE`.

## Global Constraints

- One implementation: Rust only. No per-SDK normalizer code; SDKs only call their binding.
- Never execute upstream Python or `num2words` (LGPL-2.1); German number words are written from scratch.
- `normalize_speech_text(text, locale)` never fails or panics: non-German locale → input unchanged; any stage error,
  including `fancy-regex` backtrack limits → that line unchanged (all-or-nothing per line); `\n` preserved, lines
  normalized independently.
- German locale = language subtag `de` (case-insensitive, `-` or `_`): `de`, `de-DE`, `de-AT`, `de-CH`.
- `de-AT` writes month 1 as `Jänner`; every German locale accepts `Jänner` wherever upstream accepts `Januar`.
- Number word conventions follow `num2words` German as upstream used it: `eins` alone, `ein-` in compounds,
  `einhundert`, `eintausend`, `eine Million`, `zwei Millionen`, years 1100–1999 as `neunzehnhundertneunzig`.
- Out of scope (stay raw): Markdown, LaTeX, emoji, URLs, e-mail, phone numbers, postcodes, Unicode math, `2x täglich`,
  `×` outside digits, `+`, word slashes; English normalization; streaming.
- Ported files and copied tables keep upstream attribution: `rust/inderun-route-core/src/speech_text/NOTICE` with
  "Articulino-DE-EN-Realtime-Stream-TTS, Copyright 2026 eigenhand, Apache License 2.0", naming `german.py`,
  `abbreviations.json`, `units.json` as the sources.
- Route-core changes: rebuild and commit `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework` and its
  `InderunRouteCoreFFI.provenance.json` with `pnpm build:route-core-apple` in the same task that changes the crate's
  exports; `pnpm verify:route-core-apple` must pass. Do not restate the Rust toolchain version anywhere.
- No new dependency in any published Android/Swift/npm module; `pnpm verify:android-api-deps` stays green; consumer
  smoke targets untouched.
- Branch `feat/m5-german-frontend` off `dev` (after #272 and #273 merge), PR into `dev`; Conventional Commits; trailers
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01HKCoLXyV9eTB812cpAucTi` last.
- The fixture expectations pinned in Tasks 2–3 were derived by reading `german.py`. Where careful reading of the
  source shows one is wrong (for example a table entry overrides a rule), the source wins: fix the expectation and
  name the case and the reason in the task report.
- Formatting: `cargo fmt`, `cargo clippy -- -D warnings`, Prettier, `swiftlint lint --strict` (140 cols),
  `./gradlew spotlessApply`.

## Review Focus

1. Multibyte text (`ü`, `ß`, `€`, `°C`, emoji, Cyrillic) next to matches: Rust byte slicing must never panic —
   `utf8_safety_near_matches` fixture case and `never_panics_on_mixed_scripts` test (Task 2).
2. Adversarial or very long input (`"1." * 5000`, 20 000 chars without spaces): returns within a second, unchanged or
   normalized, never panics — `long_and_adversarial_input_is_bounded` test (Task 3).
3. Non-German locales and empty/whitespace text are byte-identical — `english_passes_through`, `empty_text`,
   `whitespace_only` fixture cases (Task 2), and the provider tests in Tasks 4–6 show a fixture-runtime request is
   unchanged.
4. Abbreviation periods no longer end sentences: provider test `Am 3. Mai, z. B. um 14:30 Uhr.` yields exactly one
   sentence `Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig.` (Tasks 4–6).
5. A `de-AT` request on a voice listing only `de-DE` still gets `Jänner` (spec ruling 2): provider test in Tasks 4–6.

---

### Task 1: Crate groundwork — `fancy-regex`, entry point, German number words

**Files:**
- Modify: `rust/inderun-route-core/Cargo.toml` (add `fancy-regex`), `rust/inderun-route-core/src/lib.rs`
- Create: `rust/inderun-route-core/src/speech_text/mod.rs`, `src/speech_text/number_words.rs`, `src/speech_text/NOTICE`
- Test: unit tests inside `number_words.rs` and `mod.rs`

**Interfaces:**
- Produces: `pub fn normalize_speech_text(text: &str, locale: &str) -> String` (re-exported at crate root);
  `pub(crate) fn is_german(locale: &str) -> bool`; `pub(crate) fn cardinal(n: u64) -> String`;
  `pub(crate) fn ordinal(n: u64, ending: &str) -> String` (ending one of `""`, `"n"`, `"r"`, `"m"`, `"s"`);
  `pub(crate) fn year(n: u64) -> String` (1100–1999 → `neunzehnhundertneunzig`, else `cardinal`).
  In this task `normalize_speech_text` splits on `\n`, runs an empty German stage list per line for German locales
  and returns the joined text.

- [ ] **Step 1: Write failing tests**

```rust
#[test] fn cardinals() {
    for (n, w) in [(0,"null"),(1,"eins"),(7,"sieben"),(11,"elf"),(16,"sechzehn"),(17,"siebzehn"),(21,"einundzwanzig"),
                   (30,"dreißig"),(70,"siebzig"),(100,"einhundert"),(101,"einhunderteins"),(1000,"eintausend"),
                   (1001,"eintausendeins"),(1250,"eintausendzweihundertfünfzig"),(2026,"zweitausendsechsundzwanzig"),
                   (1_000_000,"eine Million"),(2_000_000,"zwei Millionen"),(1_000_000_000,"eine Milliarde")] {
        assert_eq!(cardinal(n), w, "{n}");
    }
}
#[test] fn ordinals() {
    for (n, e, w) in [(1,"","erste"),(3,"n","dritten"),(7,"r","siebter"),(8,"","achte"),(20,"m","zwanzigstem"),
                      (21,"","einundzwanzigste"),(31,"n","einunddreißigsten"),(100,"","einhundertste")] {
        assert_eq!(ordinal(n, e), w, "{n}{e}");
    }
}
#[test] fn years() { assert_eq!(year(1990), "neunzehnhundertneunzig"); assert_eq!(year(2026), "zweitausendsechsundzwanzig"); assert_eq!(year(1100), "elfhundert"); }
#[test] fn german_locales() { for l in ["de","de-DE","DE_at","de-CH"] { assert!(is_german(l), "{l}"); } for l in ["en-US","","deu","d"] { assert!(!is_german(l), "{l}"); } }
#[test] fn lines_and_locales_pass_through() {
    assert_eq!(normalize_speech_text("Call me at 3.", "en-US"), "Call me at 3.");
    assert_eq!(normalize_speech_text("a\nb\n", "de-DE"), "a\nb\n");
    assert_eq!(normalize_speech_text("", "de-DE"), "");
}
```

- [ ] **Step 2: Run and see them fail** — `cargo test -p inderun_route_core speech_text` → compile errors (module missing).
- [ ] **Step 3: Implement** the module, number words (own algorithm; billions/millions as separate words with
  `eine`/plural, below a million joined), `is_german`, and the per-line skeleton; add `fancy-regex` (latest 0.x) to
  `Cargo.toml`; write the NOTICE.
- [ ] **Step 4: Prove the dependency builds everywhere the crate ships:**
  `cargo test -p inderun_route_core`;
  `RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown --release`;
  `cargo build -p inderun_route_core --features jni-bindings`;
  `cargo build -p inderun_route_core --target aarch64-apple-ios --release`. Record the size of the release `.wasm`
  before (on `dev`) and after in the task report. Expected: all build; tests PASS.
- [ ] **Step 5:** `cargo fmt -p inderun_route_core -- --check && cargo clippy -p inderun_route_core --all-targets -- -D warnings`; commit `feat(route-core): add the speech text entry point and German number words`.

---

### Task 2: Units, numbers, dates, times, money (+ fixture)

**Files:**
- Create: `rust/inderun-route-core/src/speech_text/german/{mod.rs,units.rs,numbers.rs}`,
  `src/speech_text/data/units.json` (copied unchanged), `contracts/fixtures/speech/german-frontend.json`
- Modify: `src/speech_text/mod.rs` (stage list), `docs/speech-conformance.md` (fixture row; runners named in Tasks 4–6)
- Test: `rust/inderun-route-core/src/speech_text/tests.rs` (fixture runner + Review Focus 1)

**Interfaces:**
- Consumes: Task 1's number words.
- Produces: fixture shape `{ "$comment": string, "cases": [{ "id": string, "locale": string, "input": string, "expected": string }] }`;
  `fn expand_units(text: &str) -> Result<String, StageError>`, `fn numbers(text: &str, locale: &str) -> Result<String, StageError>`
  (`StageError` wraps `fancy_regex::Error`; any `Err` makes the line pass through unchanged).

Port `expand_units` and `numbers` from `german.py` strictly (spec ruling 5), in upstream's order, with Jänner (Global
Constraints). Rust `fancy-regex` lacks Python's `re.sub` with a callback: iterate captures and build the output; slice
only at match boundaries (`Match::start/end` are byte offsets on char boundaries).

- [ ] **Step 1: Write the fixture's number, unit and date cases and the runner.** At least these ids with these exact
  pairs, plus one case per remaining upstream rule in `expand_units`/`numbers` (about 30 total in this task):

| id | locale | input | expected |
| --- | --- | --- | --- |
| `english_passes_through` | en-US | `Call me at 3.` | `Call me at 3.` |
| `empty_text` | de-DE | `` | `` |
| `whitespace_only` | de-DE | `  ` | `  ` |
| `date_ordinal_after_am` | de-DE | `Am 3. Mai um 14:30 Uhr.` | `Am dritten Mai um vierzehn Uhr dreißig.` |
| `money_euro_cents` | de-DE | `Das kostet 12,50 €.` | `Das kostet zwölf Euro fünfzig.` |
| `unit_compound` | de-DE | `Er fährt 50 km/h.` | `Er fährt fünfzig Kilometer pro Stunde.` |
| `unit_one_nominative` | de-DE | `Es dauert 1 h.` | `Es dauert eine Stunde.` |
| `unit_one_dative` | de-DE | `Es ist in 1 h fertig.` | `Es ist in einer Stunde fertig.` |
| `date_numeric_with_year` | de-DE | `Am 3.1.2026 ist Ruhetag.` | `Am dritten Januar zweitausendsechsundzwanzig ist Ruhetag.` |
| `jaenner_de_at` | de-AT | `Am 3.1.2026 ist Ruhetag.` | `Am dritten Jänner zweitausendsechsundzwanzig ist Ruhetag.` |
| `jaenner_accepted_de_de` | de-DE | `Am 3. Jänner.` | `Am dritten Jänner.` |
| `year_form` | de-DE | `Das war 1990.` | `Das war neunzehnhundertneunzig.` |
| `leading_zero_digits` | de-DE | `Agent 007.` | `Agent null null sieben.` |
| `decimal_comma` | de-DE | `Es sind 3,5 Grad.` | `Es sind drei Komma, fünf Grad.` |
| `thousands_point` | de-DE | `Es kamen 1.250 Besucher.` | `Es kamen eintausendzweihundertfünfzig Besucher.` |
| `utf8_safety_near_matches` | de-DE | `Grüße 😀 am 3. März für 5 €!` | `Grüße 😀 am dritten März für fünf Euro!` |

  Rust test `fixture_cases_match` loads the file with `include_str!("../../../../contracts/fixtures/speech/german-frontend.json")`,
  asserts ids are unique and every case equals `normalize_speech_text(input, locale)`, reporting all mismatches at once.
  Test `never_panics_on_mixed_scripts` runs 50 strings mixing Cyrillic, emoji, `ß`, digits and periods.
- [ ] **Step 2: Run** `cargo test -p inderun_route_core speech_text` → the number cases FAIL (stages missing).
- [ ] **Step 3: Implement** the two stages; copy `units.json` unchanged; add the fixture row to
  `docs/speech-conformance.md`.
- [ ] **Step 4: Run** → PASS. **Step 5:** fmt, clippy; commit `feat(route-core): write out German numbers, dates, times, money and units`.

---

### Task 3: Abbreviations, acronyms, spelling out, final tidy

**Files:**
- Create: `src/speech_text/german/{abbreviations.rs,letters.rs}`, `src/speech_text/data/abbreviations.json` (unchanged copy)
- Modify: `src/speech_text/german/mod.rs`, `contracts/fixtures/speech/german-frontend.json`, `src/speech_text/tests.rs`

Port `expand_abbreviations` (with `_WEEKDAY_RANGE`, `_keep_period`), `spell_out_letters` (letter names, short words,
always-spelled set, shouting rule, Roman numerals, vowel-less runs, single letters) and `normalize`'s final tidy (word
slash rule excluded — spec non-goal; whitespace collapse; no space before punctuation). Stage order: units, numbers,
abbreviations, spelling out, tidy.

- [ ] **Step 1: Add fixture cases** (about 15), at least:

| id | locale | input | expected |
| --- | --- | --- | --- |
| `abbreviation_mid_sentence` | de-DE | `Obst, z. B. Äpfel.` | `Obst, zum Beispiel Äpfel.` |
| `abbreviation_spacing_variant` | de-DE | `Obst, z.B. Äpfel.` | `Obst, zum Beispiel Äpfel.` |
| `abbreviation_keeps_final_period` | de-DE | `Das ist ca. 5 m lang usw.` | `Das ist circa fünf Meter lang und so weiter.` |
| `weekday_range` | de-DE | `Offen Mo–Fr.` | `Offen Montag bis Freitag.` |
| `acronym_spelled` | de-DE | `Das PDF ist da.` | `Das peh deh eff ist da.` |
| `acronym_shouting_kept` | de-DE | `BITTE NICHT STÖREN.` | `BITTE NICHT STÖREN.` |
| `roman_numeral_kept` | de-DE | `Ludwig II kam.` | `Ludwig II kam.` |
| `no_space_before_punctuation` | de-DE | `Das kostet 5 € .` | `Das kostet fünf Euro.` |

  Test `long_and_adversarial_input_is_bounded`: `"1. ".repeat(5000)`, `"a".repeat(20000)`, `"z. B. ".repeat(3000)`
  each return within 1 s (measured with `std::time::Instant`) and do not panic.
- [ ] **Step 2: Run** → new cases FAIL. **Step 3: Implement.** **Step 4: Run** → PASS (all fixture cases, ≥ 45 total).
- [ ] **Step 5:** fmt, clippy; commit `feat(route-core): write out German abbreviations and spell out acronyms`.

---

### Task 4: Web — WASM export, loader, hook, provider

**Files:**
- Modify: `rust/inderun-route-core/src/ffi.rs` (wasm export `normalize_speech_text(text: &str, locale: &str) -> String`),
  `packages/inderun-route-core-wasm/src/index.ts`, `packages/inderun-route-core-wasm/README.md`,
  `packages/inderun-web/src/providers/neural-speech/{runtime.ts,provider.ts,onnx-runtime.ts,articulino/runtime.ts}`
- Test: `packages/inderun-route-core-wasm/test/*` (binding), `packages/inderun-web/src/providers/neural-speech/german-frontend.conformance.test.ts`,
  `provider.test.ts`

**Interfaces:**
- Produces: `export async function normalizeSpeechText(text: string, locale: string): Promise<string>` (initializes
  like `planRouteJson`); `NeuralSpeechRuntime.normalizeText?(pkg: ModelPackage, text: string, locale: string): string | Promise<string>`.
- Provider: `const spokenLocale = sameLanguage(speech.locale, resolved.locale) ? speech.locale : resolved.locale;`
  `text = (await runtime.normalizeText?.(pkg, speech.text, spokenLocale)) ?? speech.text` before `sentencesOf`.
  **Ruling (plan):** the hook takes the package, because the composed runtime decides per package (`pipeline ===
  "articulino"`); cost if wrong: one parameter.
- Articulino runtime (and the composed ORT runtime forwarding to it for `pipeline === "articulino"`): returns
  `normalizeSpeechText(text, locale)` when `pkg.speech?.frontend?.kind === "grapheme"`, else `text`.

- [ ] **Step 1: Tests.** `german-frontend.conformance.test.ts` runs every fixture case through the real WASM
  `normalizeSpeechText` (guard: case count equals the fixture's). `provider.test.ts`: a runtime whose `normalizeText`
  delegates to the real binding and records `synthesize` inputs; `Am 3. Mai, z. B. um 14:30 Uhr.` at `de-DE` →
  exactly one sentence `Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig.`; at `de-AT` on a voice whose locales
  are only `["de-DE"]`, `Am 3.1.2026.` → `Am dritten Jänner zweitausendsechsundzwanzig.`; the fixture runtime
  (no hook) receives the text unchanged.
- [ ] **Step 2: Run** `pnpm test:js` → FAIL. **Step 3: Implement.** **Step 4:** `pnpm test:js && pnpm lint && pnpm format:check:js && pnpm build && pnpm verify:packaging` → PASS.
- [ ] **Step 5:** commit `feat(web): normalize German text before neural speech sentence splitting`.

---

### Task 5: Android — JNI export, Kotlin binding, hook, provider

**Files:**
- Modify: `rust/inderun-route-core/src/ffi.rs` (`Java_app_independo_inderun_core_SharedCoreSpeechText_normalizeNative`,
  same `with_env` pattern as the planner),
  `android/inderun-core/src/main/kotlin/app/independo/inderun/core/SharedCoreSpeechText.kt` (new public object, KDoc
  "serves the neural speech pipelines; not a stable API"),
  `android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech/{NeuralSpeechRuntime.kt,NeuralSpeechProvider.kt,articulino/ArticulinoRuntime.kt}`,
  `android/inderun-onnx-providers/src/main/kotlin/app/independo/inderun/providers/onnx/OnnxNeuralSpeechRuntime.kt`
- Test: `android/inderun-neural-speech/src/test/.../GermanFrontendConformanceTest.kt`, `NeuralSpeechProviderTest.kt`

**Interfaces:**
- Produces: `object SharedCoreSpeechText { fun normalize(text: String, locale: String): String }` (loads
  `inderun_route_core` like `SharedCoreRoutePlanner`); `fun normalizeText(modelPackage: ModelPackage, text: String, locale: String): String = text`
  default on `NeuralSpeechRuntime`; Articulino and the ORT composed runtime as in Task 4 (Web): `ArticulinoRuntime.normalizeText` helper used when `pipeline == "articulino"`. Provider: same spoken-locale
  rule, before `sentencesOf`.

- [ ] **Step 1: Tests** mirroring Task 4, on the host library the JVM tests already load.
- [ ] **Step 2: Run** `cd android && ./gradlew :inderun-neural-speech:testDebugUnitTest` → FAIL.
- [ ] **Step 3: Implement.** **Step 4:** `cd android && ./gradlew spotlessApply test spotlessCheck && cd .. && pnpm verify:android-api-deps` → PASS.
- [ ] **Step 5:** commit `feat(android): normalize German text before neural speech sentence splitting`.

---

Ordering: the XCFramework provenance hashes every file under `rust/inderun-route-core/src`, so the Apple task, which
rebuilds it, is the last task that changes the crate.

### Task 6: Apple — C export, XCFramework, hook, provider

**Files:**
- Modify: `rust/inderun-route-core/src/ffi.rs` (`#[unsafe(no_mangle)] pub unsafe extern "C" fn inderun_normalize_speech_text(text: *const c_char, locale: *const c_char) -> *mut c_char`,
  null → empty string, freed by `inderun_free_string`), `rust/inderun-route-core/include/inderun_route_core.h`,
  `scripts/verify-route-core-apple.mjs` (`SYMBOLS` adds `_inderun_normalize_speech_text`),
  `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework` + provenance (rebuilt),
  `ios/IndeRun/Sources/IndeRunCore/SharedCoreSpeechText.swift` (new),
  `ios/IndeRun/Sources/IndeRunNeuralSpeech/{NeuralSpeechRuntime.swift,NeuralSpeechProvider.swift,Articulino/ArticulinoRuntime.swift}`,
  `ios/IndeRun/Sources/IndeRunOnnxProviders/OnnxNeuralSpeechRuntime.swift`,
  `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAINeuralSpeechRuntime.swift`
- Test: `ios/IndeRun/Tests/IndeRunTests/GermanFrontendConformanceTests.swift`, `NeuralSpeechProviderTests.swift`

**Interfaces:**
- Produces: `package enum SharedCoreSpeechText { package static func normalize(_ text: String, locale: String) -> String }`;
  `NeuralSpeechRuntime.normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String` with a
  protocol-extension default returning `text`; `ArticulinoRuntime.normalizeText` (static helper used by both composed
  runtimes when `pipeline == "articulino"`). Provider: same spoken-locale rule as Task 4, before `sentences(of:)`.

- [ ] **Step 1: Tests** mirroring Task 4 (fixture through the real binding with a count guard; the three provider cases).
- [ ] **Step 2: Run** `swift test --filter "GermanFrontend|NeuralSpeechProvider"` → FAIL (compile).
- [ ] **Step 3: Implement**, then `pnpm build:route-core-apple` and commit the regenerated XCFramework and provenance.
- [ ] **Step 4:** `pnpm verify:route-core-apple && swift test && (cd ios/IndeRun && swiftlint lint --strict)` → PASS;
  also `swift build --target IndeRunCoreAIProviders`. Record XCFramework slice sizes before/after.
- [ ] **Step 5:** commit `feat(apple): normalize German text before neural speech sentence splitting`.

---

### Task 7: ADR 023 and documentation

**Files:**
- Create: `docs/architecture/decisions/023-german-text-frontend.md`
- Modify: `docs/architecture/decisions/README.md`, `docs/architecture/neural-speech-provider-family.md` (sentence
  splitting: drop "no abbreviation handling"; limitations; seam method `normalizeText`), `docs/architecture/providers.md`
  (neural speech and Core AI rows: German text normalization), `docs/ci.md` (route-core verification names the new
  symbol), `docs/migration.md` (additive: optional `normalizeText` on all three runtime seams; `SharedCoreSpeechText`
  on Kotlin; `normalizeSpeechText` in the wasm package), `CONTEXT.md` §3 (one clause: German frontend ships),
  `rust/inderun-route-core/README.md` (the crate also hosts speech text normalization).

- [ ] **Step 1:** ADR 023 (template of `decisions/README.md`, Status Accepted): context (letters-only model, upstream
  frontend), decision (one Rust implementation in the route core; pre-split hook on the runtime seam, async on Web;
  scope; Jänner; all-or-nothing per line; attribution), consequences (XCFramework rebuild per normalizer change; WASM
  size delta from Task 1; English unchanged; follow-ups: markup/URLs/phone stages, English, streaming).
- [ ] **Step 2:** the doc edits above, high level only (CLAUDE.md §8).
- [ ] **Step 3:** `pnpm format:check` → PASS; commit `docs(adr): record the German text frontend (ADR 023)`.

---

### Task 8: Whole-branch verification

- [ ] `pnpm test:js && pnpm test:rust && swift test && (cd android && ./gradlew test spotlessCheck) && (cd ios/IndeRun && swiftlint lint --strict) && pnpm format:check && pnpm build && pnpm verify:packaging && pnpm verify:android-api-deps && pnpm verify:route-core-apple && cargo clippy -p inderun_route_core --all-targets -- -D warnings`
  → all PASS. Optional with a phone at hand: `tools/neural-speech/ios_device_bench.sh` (no change expected).
- [ ] Squash per session convention into one `feat(providers): normalize German text before neural speech (#260)`
  commit, push, open the PR into `dev`.
