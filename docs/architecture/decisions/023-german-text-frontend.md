# ADR 023 — German text frontend

Update 2026-11-10: English normalization was added later; see the English fixture `contracts/fixtures/speech/english-frontend.json`.
German money also accepts a decimal point, a dash (`3,- €`) and cents-only amounts; the German fixture now holds 88 cases.

## Status

Accepted. Recorded for Milestone 5 (issue #260, PR 4b). It builds on the Articulino pipeline of
[ADR 020](./020-neural-speech-and-model-packages.md) and the seams of the
[neural speech family](../neural-speech-provider-family.md).

## Context

Articulino reads letters. Its tokenizer maps each code point through a vocabulary, so digits, abbreviations and symbols
that the model never saw in training reach it raw: "Am 3. Mai um 14:30 kostet es 12,50 €" is read badly, `km/h` and
`PDF` come out as made-up words, and `z.B. Hallo` was two sentences because the sentence split ended at the
abbreviation's period. The upstream model was evaluated with a German text frontend (`frontend/german.py` in the
Articulino release, Apache-2.0, with two data tables). The neural speech family needs the same behaviour on the Web,
Apple and Android SDKs, and three hand-written ports would drift.

## Decision

### 1. One Rust implementation in the route core

A `speech_text` module in the `inderun_route_core` crate, behind the Cargo feature `speech-text` (default on), exposes
`normalize_speech_text(text, locale)`. For a locale whose language subtag is `de` it runs the stages listed in `STAGES` in `src/speech_text/mod.rs`, in that
order; for any other locale it returns the text unchanged.
Behaviour is ported from upstream by reading the Apache-2.0 source. The notice and the two data tables
(`abbreviations.json`, `units.json`, copied unchanged) sit in `src/speech_text/NOTICE` and `src/speech_text/data/`.
German number words are our own implementation (num2words convention, not the LGPL `num2words` package). The rules use
lookaround, so the crate depends on `fancy-regex`. Deviations from upstream are recorded in
`src/speech_text/german/mod.rs`; the stage order and rules live in code comments, not here.

### 2. Per-line, all-or-nothing

The normalizer works line by line and keeps every `\n`, so the provider's newline split is unchanged and no rule spans
lines. Any stage error on a line (a regex backtrack limit, a number that overflows) leaves that line unchanged: text it
does not understand passes through, never partly normalized and never a failure.

### 3. Jänner

For `de-AT` the month 1 is written `Jänner` when a numeric date is expanded, and `Jänner` is accepted as a month name
in every German locale wherever upstream accepts `Januar`. Other locales keep `Januar`.

### 4. Pre-split hook on the runtime seam

`NeuralSpeechRuntime` gets an optional `normalizeText(modelPackage, text, locale)` on all three SDKs (a TypeScript
optional member that may return a Promise, a Swift protocol-extension default, a Kotlin default method), defaulting to
the identity. `NeuralSpeechProvider` calls it once per request on the whole text, before sentence splitting, so the
split sees written-out abbreviations. The locale is the request locale when its language equals a voice locale's
language, otherwise the voice's first locale; so a `de-AT` request on a voice that lists only `de-DE` still gets
`Jänner`. The Articulino runtimes implement it when `speech.frontend.kind` is `grapheme`; the composed ONNX Runtime and
Core AI runtimes forward for `pipeline == articulino`. The hook sits on the runtime, not in the provider, because
normalization belongs to a model family's frontend. The fixture runtime keeps the default, so every lifecycle and
pipeline fixture is unchanged.

### 5. A separate artifact for the normalizer

Regexes and tables grow each artifact about fourfold to fivefold, and most apps never use neural speech. So the
planner artifacts every app loads are built without `speech-text` and keep their size, and the normalizer ships as its
own artifact that only neural speech loads:

- **Web.** `@independo/inderun-route-core-wasm` builds two modules: `inderun_route_core` (the planner) and
  `inderun_speech_text`, loaded lazily by `normalizeSpeechText()`. `initSpeechText(moduleOrPath?)` is the counterpart
  of the planner's initializer for hosts that serve the wasm from a custom path. What ships is the size-optimised `wasm` cargo profile (opt-level "z", fat LTO), which
  `scripts/build-route-core-wasm.mjs` builds and `release.yml` publishes, gated by `pnpm check:wasm-size`:
  `inderun_route_core_bg.wasm` is about 333 KB (about 104 KB gzip) and `inderun_speech_text_bg.wasm` is about 1.69 MB
  (about 535 KB gzip).
- **Android.** `:inderun-core` packages the planner-only `libinderun_route_core.so` (about 0.71 MB arm64).
  `:inderun-neural-speech` packages `libinderun_speech_text.so` (about 2.34 MB arm64, its own soname) and an internal
  `SharedCoreSpeechText` object.
- **Apple.** The committed `InderunRouteCoreFFI.xcframework` stays planner-only with unchanged sizes. A second committed
  `InderunSpeechTextFFI.xcframework` (about 1.6 MB for ios-arm64) has its own provenance manifest and verification and
  is linked only by `IndeRunNeuralSpeech`, through an internal `SharedCoreSpeechText` and the C functions
  `inderun_normalize_speech_text` and `inderun_speech_text_free`. The C interface passes the text as UTF-8 bytes with
  a length in both directions, so an embedded U+0000 does not cut the text short on Apple, as it does not on the Web or
  Android.

`SharedCoreSpeechText` is internal to the neural speech modules on Android and Apple; there is no public API for it.

### 6. Unavailable artifact is a routing outcome

If the speech artifact cannot be loaded (Web, Android), the provider fails with `Unavailable` before any audio output
is opened and before commit, so routing can fall back to the next target. A run that was already cancelled takes the
cancellation path instead.

### 7. Verification

`contracts/fixtures/speech/german-frontend.json` holds 83 cases (`id`, `locale`, `input`, `expected`), derived by hand
from the upstream source and independently re-derived in review. Each SDK runs every case through its binding. No
upstream code or `num2words` was run to produce expectations.

## Consequences

- German text is spoken correctly on every SDK from one implementation, and abbreviation periods no longer end
  sentences. English is normalized the same way (see `contracts/fixtures/speech/english-frontend.json`); other locales are unchanged.
- A change to the normalizer rebuilds and recommits `InderunSpeechTextFFI.xcframework` (`pnpm build:route-core-apple`),
  gated by `pnpm verify:route-core-apple`. A Cargo bump affects both frameworks.
- The Web SDK fetches an extra module (about 1.32 MB gzip as shipped) the first time neural speech speaks
  German-capable text, and hosts with a custom wasm path must call `initSpeechText`. Android neural speech apps carry about 2.3 MB more per ABI.
- Apps that do not use neural speech pay nothing.
- Follow-ups:
  - Build the wasm modules with an optimized release profile (opt-level z), as the Apple and Android profiles do. The
    Web sizes above are the debug build and shrink considerably.
  - The speech artifacts also carry a planner copy (about 0.4 MB), because the planner exports are unconditional.
    Making them conditional would shrink each speech artifact.
  - The upstream stages for markup, LaTeX, e-mail and web addresses, phone numbers and Unicode math are not ported;
    they target language-model output and can be added behind the same function.
  - English normalization is done: the same function normalizes `en*` locales and every SDK's Articulino runtime
    forwards them to the normalizer (`contracts/fixtures/speech/english-frontend.json`). Streaming normalization is not implemented.
  - A one-time typed reference comparison against upstream, if the owner allows running it, would check the fixture
    expectations. The fixture format allows it.
