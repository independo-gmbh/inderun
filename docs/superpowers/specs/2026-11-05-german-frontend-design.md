# #260 PR 4b — German text frontend for neural speech

Status: design, written while the owner was away (owner delegated the gate: "you are on your own"). Decisions the
owner made are marked **owner**; the rest are the author's calls, marked **ruling**, with the cost if wrong.

## Why

Articulino reads letters. It never saw digits, abbreviations or symbols in training, so "Am 3. Mai um 14:30 kostet es
12,50 €" is read badly today: digits pass through the tokenizer raw, `z.B. Hallo` is split into two sentences at the
abbreviation's period (family doc, "Sentence splitting"), and `km/h` or `PDF` come out as made-up words. The upstream
model was evaluated with a German frontend (Apache-2.0, `frontend/german.py` in the Articulino release, 815 lines of
Python plus `abbreviations.json` and `units.json`). PR 4b brings the parts of it that matter for spoken German to all
three SDKs, with one implementation.

## Goals

- German text is written out before the provider splits it into sentences: numbers, ordinals, decimals, times, dates
  (Jänner for de-AT), money, units, abbreviations, acronyms and a digit-by-digit fallback (spec, PR table row 4b).
- One implementation, in Rust, in the route core, reached through the bindings each SDK already loads (**owner**:
  "One Rust port").
- The same text gives the same normalized text on Web, Apple and Android, pinned by one shared fixture run on every SDK.
- Abbreviation periods no longer end sentences, because the abbreviation is written out before the split.

## Non-goals

- Markdown, LaTeX, emoji, smileys, e-mail and web addresses, phone numbers, postcodes and Unicode math (upstream
  stages `clean_markup`, `latex`, `math_symbols`, `phone_numbers`). They target language-model output; a follow-up can
  add them behind the same function. (**ruling**: scope as the spec row lists it — cost if wrong: one follow-up PR.)
- English normalization. Upstream has none; English text passes unchanged.
- Streaming normalization (`StreamNormalizer`): `speak()` hands the provider the whole text.
- Phonemes or any G2P; that is PR 9.

## Anti-goals

- Executing upstream code or `num2words` (LGPL-2.1) to produce expectations. The port is written from reading the
  Apache-2.0 source; German number words are our own implementation. (**ruling**, as in PR 4a's host-math port — cost
  if wrong: fixture expectations need a second human read, which the review provides.)
- A second implementation per SDK. If a binding cannot reach the route core, the hook is identity there, not a port.
- Any change to routing or the planner's behaviour.

## Constraints

- The route core is the `inderun_route_core` crate (`rust/inderun-route-core`). Web loads it as WASM
  (`packages/inderun-route-core-wasm`, no fallback), Apple as the committed `InderunRouteCoreFFI.xcframework` (rebuilt
  with `pnpm build:route-core-apple`, provenance regenerated, `pnpm verify:route-core-apple` must pass), Android as the
  JNI library Gradle builds (`jni-bindings` feature). A dependency bump changes `Cargo.lock` and so the provenance.
- The Rust toolchain is pinned in `rust-toolchain.toml`; nothing restates it.
- Apache-2.0 attribution: the ported code and the two JSON tables keep upstream's notice (`Copyright 2026 eigenhand`,
  Apache License 2.0) in a NOTICE next to them, as PR 4a did for the host math.
- Architecture docs stay high level (CLAUDE.md §8): the stage list and order live in code comments.

## Design

### 1. Where it lives

A `speech_text` module in the route core crate (`src/speech_text/`), with one public function:

```rust
pub fn normalize_speech_text(text: &str, locale: &str) -> String
```

For a locale whose language is `de` (`de`, `de-DE`, `de-AT`, `de-CH`, any case, `_` or `-`) it runs the German
stages; for any other locale it returns the text unchanged. It never fails: text it does not understand passes
through. (**ruling**: one crate rather than a second `inderun_speech_text` crate, because every binding and its build,
packaging, provenance and verification scripts already exist for this one — cost if wrong: the route core carries a
second responsibility; splitting later moves one module.)

Stages, in upstream's order restricted to the scope above: units (`expand_units`), numbers (`numbers`, with its date,
time, money, fraction, ordinal, decimal, range, minus and integer rules), abbreviations (`expand_abbreviations`),
spelling out (`spell_out_letters`), then the final whitespace and punctuation tidy of `normalize`. The upstream rules
use lookaround, so the port uses `fancy-regex` (MIT, built on `regex`). (**ruling**: a faithful regex port beats a
hand-written scanner for review against the source — cost if wrong: WASM and XCFramework size grow; the PR records
the size delta of each artifact.)

German number words are a module of their own: cardinal (`null` … below 10^12, `eins` alone but `ein-` in compounds),
ordinal stem plus ending (`dritte`, `dritten`, `drittes`, …), and the year form for 1100–1999
(`neunzehnhundertneunzig`). Upstream's rule set picks among them exactly as in `german.py`; where upstream calls
`num2words`, the port calls these.

### 2. Jänner

For `de-AT` the month 1 is written `Jänner` when a numeric date is expanded (`3.1.2026` → `dritter Jänner
zweitausendsechsundzwanzig`), and `Jänner` is accepted as a month name in every German locale wherever upstream
accepts `Januar` (dates, the list-number exception). Other locales keep `Januar`. (**ruling** — cost if wrong: one
table entry.)

### 3. The data tables

`abbreviations.json` and `units.json` are copied unchanged into `rust/inderun-route-core/src/speech_text/data/` and
compiled in with `include_str!`, parsed once on first use. They are not a shared contract fixture: only the Rust code
reads them.

### 4. Bindings

Each binding gets one entry point next to the planner's, with the same ownership rules:

- C: `inderun_normalize_speech_text(text, locale) -> *mut c_char`, freed with the existing `inderun_free_string`.
  A null argument returns an empty string. `scripts/verify-route-core-apple.mjs` adds the symbol to its export list.
- JNI: `Java_app_independo_inderun_core_SharedCoreSpeechText_normalizeNative(text, locale)`, an `internal`-by-intent
  Kotlin object `SharedCoreSpeechText` in `:inderun-core` next to `SharedCoreRoutePlanner`, loaded the same way.
- WASM: `normalize_speech_text(text, locale)`, re-exported by `@independo/inderun-route-core-wasm`.

### 5. The pre-split hook

The neural speech runtime seam gets one optional, synchronous method, called by `NeuralSpeechProvider` on the whole
request text, before `splitSentences`:

- TS: `normalizeText?(text: string, locale: string): string` on `NeuralSpeechRuntime`.
- Swift: `func normalizeText(_ text: String, locale: String) -> String`, with a protocol-extension default returning
  `text`.
- Kotlin: `fun normalizeText(text: String, locale: String): String = text`, a default method.

The locale is the resolved voice locale the provider already computes. The Articulino pipeline runtimes implement it
by calling the route core when the package's `speech.frontend.kind` is `grapheme`; the composed ORT and Core AI
runtimes forward to their pipeline runtime. The fixture runtime keeps the default, so every lifecycle and pipeline
fixture stays byte-identical. (**ruling**: on the runtime seam, not in the provider, because normalization belongs to
a model family's frontend — Kokoro (PR 9) normalizes differently — cost if wrong: one method moves.)

Where a platform cannot reach the route core at that point (the Web SDK before its WASM module has loaded), the
Articulino runtime awaits the same loader the planner uses during `prepare`, so `normalizeText` is synchronous by the
time a sentence is spoken. If the module cannot load, routing has already failed: the Web SDK has no planner without
it.

### 6. Fixture and tests

- `contracts/fixtures/speech/german-frontend.json`: `{ "$comment", "cases": [{ "id", "locale", "input", "expected" }] }`,
  hand-written from reading `german.py`, about 60 cases covering every rule in scope plus pass-through cases (English
  locale, text without digits, unknown symbols). Each case id names the rule (`date_numeric_with_year`,
  `jaenner_de_at`, `unit_one_dative`, …).
- Rust: `cargo test` runs every case through `normalize_speech_text`, and unit tests pin the number words (0, 1, 7,
  11, 16, 17, 21, 70, 100, 101, 1000, 1001, 1990 as a year and as a count, 2026, 1 000 000, ordinals 1–31 with each
  ending).
- Each SDK runs every fixture case through its binding (the guard is the case count), and one provider test shows the
  hook runs before the split: `Am 3. Mai, z. B. um 14:30 Uhr.` reaches the runtime as one normalized sentence.
- `neural-frontend.json` is unchanged; it pins the split, which now sees normalized text.

### 7. Documentation

ADR 020 (speech model contracts) is unchanged. A short ADR 023 records the decision: one Rust implementation in the
route core, the pre-split hook on the runtime seam, the scope, and that the route core now also hosts speech text
normalization. The family doc's "Sentence splitting" and "Limitations" paragraphs drop the abbreviation caveat and link
ADR 023; the provider matrix row notes German normalization; `docs/ci.md` names the new FFI symbol in the route-core
verification; CONTEXT.md §3 gets one clause.

## Left to the builder

- Exact fixture cases beyond the rule list, the number-word implementation, the regex translations, internal module
  layout, and test names.
- Whether `normalizeText` on the Web awaits the loader in `prepare` or reuses an already-loaded module handle, as long
  as the call is synchronous when a sentence is spoken.

## Risks

- `fancy-regex` behaviour differs from Python `re` in corner cases (Unicode `\w`, `\b`); the fixture is the arbiter.
- XCFramework size and rebuild: one committed binary change, gated by `verify:route-core-apple`.
- A regex with catastrophic backtracking on adversarial input: `fancy-regex` has a backtrack limit; on hitting it the
  stage returns its input unchanged (pass-through, never a failure).

## Settled after the builder check (all **ruling**)

1. **Reaching the normalizer.** Swift: a `package` enum `SharedCoreSpeechText` in `IndeRunCore` (which links
   `InderunRouteCoreFFI`); `IndeRunNeuralSpeech` already depends on `IndeRunCore`, so no public symbol and no new
   target dependency. Kotlin: `internal` does not cross Gradle modules, so `SharedCoreSpeechText` is a public object in
   `:inderun-core`'s `app.independo.inderun.core`, next to `SharedCoreRoutePlanner` and loaded through the same
   `System.loadLibrary("inderun_route_core")`; its KDoc says it serves the neural speech pipelines and is not a stable
   API. No dependency changes, so `published-api-dependencies.txt` and the consumer-smoke modules are untouched. Web:
   `@independo/inderun-route-core-wasm` exports `normalizeSpeechText(text, locale): Promise<string>`, which initializes
   the module on first use like `planRouteJson`. Cost if wrong: one public Kotlin object pre-1.0.
2. **Locale.** The hook receives the request locale when its language equals the resolved voice locale's language,
   otherwise the resolved voice locale. So a `de-AT` request on a voice that lists only `de-DE` still gets `Jänner`.
   Cost if wrong: one line in each provider.
3. **Fixture correctness.** No reference run of upstream code or `num2words` (anti-goal stands). The fixture is
   smaller and high-confidence (about 45 cases), each expectation written from reading `german.py`, and the task
   review derives every expectation independently from the source before comparing. The owner can later authorize a
   one-time reference comparison; the fixture format allows it. Cost if wrong: a wrong expectation pinned on three
   SDKs until a listener or that comparison catches it.
4. **Newlines.** The normalizer runs line by line and keeps every `\n`, so the provider's newline split is unchanged
   and no rule matches across lines. Cost if wrong: none observable for single-line text.
5. **Faithfulness.** The in-scope functions (`expand_units`, `numbers`, `expand_abbreviations`, `spell_out_letters`,
   and `normalize`'s final tidy) are ported strictly, including `_TIMES`, `_FRACTION`, `_RANGE`, `_MINUS` and
   `_GLUED`. What only the dropped stages do (`2x täglich`, `×` outside digits, `+`, slashes between words) stays raw.
6. **Proof beyond the fixture.** The first task adds `fancy-regex` and builds the crate for wasm32, the five Apple
   targets (through `pnpm build:route-core-apple`) and the Android host library before any rule is ported. Sizes of
   the `.wasm` and the XCFramework slices are recorded before and after; there is no size gate. Any stage error
   (including `fancy-regex`'s backtrack limit) makes `normalize_speech_text` return the original line unchanged:
   all-or-nothing per line, never partly normalized.
7. **The Web hook is asynchronous.** TS `normalizeText?(text, locale): string | Promise<string>`; the TS provider
   awaits it (its run path is already async). Swift and Kotlin stay synchronous. The Articulino web runtime calls the
   wasm package's `normalizeSpeechText`.

## Superseded during execution

- **Artifact split.** The normalizer grew each artifact about fourfold to fivefold, so it does not ship in the planner
  artifacts. Web builds a second module, `inderun_speech_text`, loaded lazily by `normalizeSpeechText()` /
  `initSpeechText()`. Android packages `libinderun_speech_text.so` in `:inderun-neural-speech`. Apple commits a second
  `InderunSpeechTextFFI.xcframework` linked only by `IndeRunNeuralSpeech`. See ADR 023 section 5.
- **`SharedCoreSpeechText` is internal** to the neural speech modules on Android and Apple. This supersedes the JNI name
  in section 4 and "Settled" item 1, which placed it in `:inderun-core` / `IndeRunCore`.
- The hook takes the model package as its first argument, and a failure to load the speech artifact is `Unavailable`
  before commit.
