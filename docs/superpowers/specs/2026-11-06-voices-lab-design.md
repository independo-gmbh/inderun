# #260 PR 6 — model catalog, consent downloaders and the Voices lab

Status: design, written while the owner was away (owner delegated the gate: "you are on your own"). Owner decisions
are marked **owner**; the rest are the author's calls, marked **ruling**, with the cost if wrong. Parent spec:
`docs/superpowers/specs/2026-11-04-neural-speech-design.md` §F (and §E for routing).

## Why

The neural speech pipeline (PR 3–5) can only be heard today through env-gated tests. The three demo apps need an
opt-in place where a person downloads a model with consent, picks a language and a voice, and compares the neural
voice against the OS voice. That is the "Voices lab". It is also where the seven own voices
(`tmp/voice-seeds-2026-11-05/`) become usable.

## Goals

- One catalog, `contracts/fixtures/speech/neural-model-catalog.json`, listing what the demos can download, each entry
  mapping 1:1 onto a `ModelPackage` (`source: app_managed`, `integrity.checksums`), shape-tested in
  `packages/contracts/src/` and copied to Android assets like the corpus.
- A consent downloader per demo (size + licence shown before anything is fetched, sha256 checked after).
- A Voices lab screen per demo, opt-in, with the controls listed in §F: language (de-DE, de-AT, en-US, en-GB)
  independent of model; model (plus "OS TTS (control)"); voice; editable presets from the corpus;
  Speak / Stop / Repeat / A-B; download/warm with size and consent; a status card (provider, model id/variant/hash,
  voice, resolved locale, locality, runtime, artifact vs playback).
- The seven own voices are available in the lab.

## Non-goals

- Benchmark targets, JSON export and `docs/verification/neural-speech*.md`: PR 7 (spec PR table). The lab's
  "export" control is PR 7's. (**ruling** — cost if wrong: one more control later.)
- Families other than Articulino (PR 8–11). The catalog format allows them.
- A Core AI entry that downloads: no `.aimodel` exists until spike 0b. The catalog carries a `manual_install` Core AI
  entry with no files, so the lab can show it as unavailable with the reason. (**ruling**)
- Capacitor (PR 13).

## Anti-goals

- Shipping weights or voices in an app bundle or in the repository, except the seven `*.seed.wav` seeds
  (**owner**: "commit only the seeds"; "never commit candidates/ (excerpts of real recordings) or *.hop1.safetensors").
- Downloading without consent, or anything starting before the lab is switched on.
- Changing SDK behaviour for the demo's sake: the lab uses public APIs only (`listVoices`, `speak`,
  `generateSpeech`, `prepare`, profiles).

## Assets and where they come from

- Upstream files (`config.json`, `int8/dit_step.onnx`, `int8/decoder.onnx`, `LICENSE`, `NOTICE`) are downloaded from
  Hugging Face at the pinned revision `a760ce8d513534111c7679751869fa4c45ef0e54` of
  `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX`, each pinned by sha256 and byte size.
- Derived files are hosted as GitHub release assets on `independo-gmbh/inderun` (**owner**: "GitHub release
  assets"): the int64-mask `text.onnx` (the rewrite in `tools/neural-speech/rewrite_text_graph.py`; the ORT
  Objective-C binding cannot feed `bool`) and the seven voice bundles. Release tag `neural-speech-assets-1`, a name
  semantic-release never produces (it tags `v*`). (**ruling** — cost if wrong: one tag rename and new URLs.)
- `tools/neural-speech/build_demo_assets.py` builds the derived files from the committed seeds and the upstream
  release (no recordings needed), writes them to an output directory with a `SHA256SUMS`, and writes the catalog's
  `files` and `voices` entries (url, sha256, bytes). Uploading the release is an outward-facing publish: the tool
  prints the exact `gh release create` command and the owner runs it, or authorizes it. Until then the lab's download
  fails with "asset not published yet (HTTP 404)". (**ruling** — cost if wrong: the demo cannot download until the
  upload.)
- Seeds are committed to `tools/neural-speech/voice-seeds/<id>.seed.wav` with a README carrying the provenance table
  (speaker description, locale, synthesis recipe, upstream revision) but no recording file names, and the note that
  the bundles derive from consented speakers. (**ruling** on location — cost if wrong: a move.)
- Catalog licence fields: the weights are Apache-2.0 with the upstream NOTICE (CC BY 4.0 attribution for the
  training corpora); the voices carry `spdx: "LicenseRef-Independo-Demo-Voices"`, `restrictions: "demo and
  evaluation use; consented speakers; legal sign-off pending (#260)"`. The entry's `review.status` is
  `benchmark_only` until the owner's legal sign-off. (**ruling** — cost if wrong: catalog text changes.)

## Catalog shape

As §F: entries `{ id, family, pipeline, version, variant, license: {spdx, url, restrictions, attribution},
review: {status, notes}, runtime: {format, platforms, minOsVersion}, sampleRate, files: [{role, path, url, sha256,
bytes}], voices: [{id, name, locales, gender?, file: {path, url, sha256, bytes}, license}] }`. A shared
`catalogEntryToModelPackage(entry, ref)` mapping per SDK turns an installed entry into a `ModelPackage` with
`source: {sourceType: app_managed, ref}` and `integrity.checksums` from the entry; the mapping is pinned by a shared
fixture case (entry → expected package JSON) run on all three SDKs. (**ruling**: one mapping per SDK pinned by one
fixture, because each demo is written in its platform's language — cost if wrong: three small functions.)

## Demos

- iOS (`ios/SampleApps/IndeRunDemo`): `VoicesLabScreen.swift`, `DemoNeuralModelDownloader.swift` (generalizes
  `DemoOnnxModelDownloader`: consent sheet with size + licence, sha256 check, `app_managed` under Application
  Support), registration in `DemoViewModel.swift` of one neural target per installed model plus the profile
  `voices-lab:<modelId>` = `[neural target, apple_system_speech]`. The Core AI provider registers too when available
  (it reports unavailable today). Opt-in through a settings toggle; the tab appears only when on.
- Android (`android/inderun-demo-app`): `VoicesLabScreen.kt`, `DemoNeuralModelDownloader.kt`, wiring in
  `AndroidDemoRuntime.kt`; the catalog asset copied like the corpus. Opt-in toggle in the existing settings store.
- Web (`packages/inderun-web-demo`): `src/voices-lab-panel.ts` behind `VITE_INDERUN_VOICES_LAB=1`; files fetched into
  OPFS and served to the runtime as `app_managed` through a package-files reader over OPFS. (**ruling**: OPFS, as §F
  says — cost if wrong: the browser must support OPFS; the panel reports it unsupported otherwise.)
- "OS TTS (control)" is the existing system speech provider; A/B plays the same text through the selected neural
  voice and the control, one after the other.
- Presets: the corpus `contracts/fixtures/speech/utterance-corpus.json` utterances, editable in the text field.

## Testing

- Contracts: a shape test of the catalog (every entry valid, every voice locale a BCP 47 tag, ids unique, sha256 hex
  of 64, bytes > 0) and the entry → package fixture, in `packages/contracts/src/`.
- Each SDK: the entry → package mapping fixture; downloader unit tests with a fake transport (consent refused → no
  request; checksum mismatch → file removed and a clear error; resume after partial failure re-downloads only missing
  files).
- The demo screens get the test level their app already has (web: DOM tests like `speech-panel.test.ts`; Android:
  view-model tests; iOS: view-model tests), not UI automation.
- A manual check list in the PR: on a phone, download, speak de-DE/de-AT/en-US, A/B against the OS voice.

## Left to the builder

Screen layout, copy, internal names, and how each demo stores the opt-in flag, within the platform's existing demo
patterns.

## Risks

- The release assets do not exist until the owner publishes them; every download test uses fakes, and the manual
  check waits for the upload.
- OPFS and large files in the browser (90 MB): progress and storage errors must be reported, not swallowed.
- Legal: voices are published as demo assets ahead of a legal sign-off; the catalog says so and `review.status`
  stays `benchmark_only`.

## Settled after the builder check (all **ruling**)

1. **Web cannot fetch GitHub release assets directly.** Checked: `github.com/.../releases/download/...` answers 302
   without `Access-Control-Allow-Origin`, so a browser `fetch` fails; Hugging Face sends CORS. The hosting decision
   stands (owner): the native demos fetch release assets directly; the web demo fetches them through a new route of
   `packages/inderun-demo-proxy` (`GET /assets?url=<catalog url>`), which forwards only URLs that appear in the
   catalog (allowlist built from the catalog at start-up), streams the body and adds CORS for the demo origin.
   Upstream Hugging Face files are fetched directly. Cost if wrong: one proxy route.
2. **`files[].path` is the package-relative local path** (flat layout as `prepare_articulino_package.py` writes:
   `config.json`, `text.onnx`, `dit_step.onnx`, `decoder.onnx`, `voices/<id>.safetensors`); `url` may point anywhere
   (`.../int8/dit_step.onnx`). `integrity.checksums` is keyed by `path`.
3. **The `speech` block is in the catalog verbatim**: each entry carries `speech: { pipeline, sampleRate, channels,
   graphs: {role: path}, frontend: {kind, assets: {config: path}} }`; the mapping copies it, adds `voices` from the
   entry's voices (`id`, `name`, `locales`, `gender`, `file: path`, `license`), and sets package
   `id = entry.id`, `version = entry.version`, `variant = entry.variant`, `format = entry.runtime.format`, `tasks = ["text_to_speech"]`,
   `runtime.minOsVersion` (only when non-null), `license`, `source = {sourceType: app_managed, ref}`, `integrity.checksums`; no `limits` are emitted (the catalog has none).
   The mapping fixture pins this exactly.
4. **Installation is all-or-nothing per entry**: one consent covers the weights and every voice of the entry (about
   87 MB + 7 × 3 MB). Resume skips files already present with a matching sha256.
5. **Voice locales come from the catalog**: each voice lists its native locale first, then the model's other
   languages (`de-at-m-1`: `["de-AT", "de-DE", "en-US"]`; `en-us-f-1`: `["en-US", "de-DE", "de-AT"]`). The lab's
   language selector does not filter voices (the model speaks German and English with every voice; the accent
   carries). en-GB is requested as en-GB and matches the voices' `en` language.
6. **All seven voices are separate catalog voices**; `de-at-m-1-alt` is named as an alternative take of the same
   speaker. The committed seed README keeps the provenance (speaker description, locale, recipe, upstream revision,
   noise seed) and drops recording file names and source durations.
7. **`app_managed` on each SDK**: iOS resolves `ref` under Application Support and Android under `filesDir`
   (existing `ModelPackageDirectory` / `OnnxModelDirectory`), so the demo downloads there and passes the package; the
   Web uses the public `OnnxNeuralSpeechRuntimeOptions.files` with an OPFS-backed `SpeechPackageFiles`. No SDK change.
8. **Bundles are rebuilt from the seeds**: hop 2 (seed → `encoder` + `voice` graphs) is deterministic, so
   `build_demo_assets.py` needs only the committed seeds and the upstream release; the catalog's sha256 values are
   those of the files the tool writes, which are the files to upload.
9. **The Core AI entry** has `review.status: manual_install`, `runtime: {format: "coreai", platforms: ["ios",
   "macos"], minOsVersion: "27.0"}`, no `files` and no `voices`; the shape test requires files and voices only for
   other statuses.
10. **The opt-in flag** is persisted with each demo's existing settings pattern (web: the env flag plus nothing
    persisted).
