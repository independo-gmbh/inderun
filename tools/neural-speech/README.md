# Neural speech preparation tool

Offline Python tooling for the neural speech provider family (`local.onnx.speech.*`). It prepares the files the SDKs read
at run time and pins the pipeline math the three SDKs implement. **Nothing here runs in CI**, and nothing it produces
(models, WAVs, packages, voice bundles) is committed; only `contracts/fixtures/speech/articulino-pipeline.json` is.

## Setup

Python 3.12 or 3.13. `onnxruntime` ships no wheel for newer interpreters (for example 3.15), so do not use a
newer `python3`.

```bash
python3.13 -m venv tools/neural-speech/.venv
tools/neural-speech/.venv/bin/pip install -r tools/neural-speech/requirements.txt
tools/neural-speech/.venv/bin/python -m unittest discover -s tools/neural-speech -p 'test_*.py'
```

The test that needs the downloaded release (below) reads its directory from `ARTICULINO_ONNX_DIR` and skips when the
variable is unset.

## Upstream input

The Articulino ONNX release `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX`
(<https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX>, Apache-2.0). Download it into one
directory with this layout:

```text
<onnx-release-dir>/config.json
<onnx-release-dir>/fp32/{text,dit_step,decoder}.onnx        (also fp16/ upstream)
<onnx-release-dir>/int8/{text,dit_step,decoder}.onnx        (about 26 MB, 28 MB, 33 MB)
<onnx-release-dir>/int8/encoder.onnx  (about 45 MB, fp16)   voice.onnx (about 81 MB, fp16)
```

`encoder` and `voice` turn a voice prompt into a voice bundle; they run here, never on a device, and never appear in a
`ModelPackage`. The tool reads whatever `<precision>/encoder.onnx` and `voice.onnx` are (upstream keeps them in fp16 in
the `int8/` directory).

## Prepare a package

```bash
tools/neural-speech/.venv/bin/python tools/neural-speech/prepare_articulino_package.py \
  --models <onnx-release-dir> --precision int8 \
  --voice <prompt.wav>:<voice-id> [--voice <other.wav>:<other-id>] \
  --out <package-dir> [--package-id articulino-de-en]
```

The prompt WAV is mono-mixed, resampled to 24 kHz and cut to at most 8 s and whole 960-sample frames; a prompt shorter
than 3 s is refused. A voice id names `voices/<voice-id>.safetensors`, so it must not be empty, `.` or `..` or contain
`/` or `\`. Without `:<voice-id>` the WAV's file name without its extension is the id; a `:` followed by a path
separator (a Windows drive path such as `C:\voices\anna.wav`) belongs to the path. The script prints each voice's
`letter_rate` and `P` (prompt frames, 125 for 5 s or more).

Output, which is also the directory layout the SDK tests expect in `INDERUN_NEURAL_SPEECH_MODEL_DIR`:

```text
<package-dir>/model-package.json        ModelPackage (format onnx, variant onnx-<precision>, speech.pipeline articulino)
<package-dir>/config.json               copied from the release; speech.frontend.assets.config
<package-dir>/text.onnx                 rewritten: text_mask is an int64 input (see below)
<package-dir>/dit_step.onnx, decoder.onnx
<package-dir>/voices/<voice-id>.safetensors
```

`integrity.checksums` lists the sha256 of every file above except `model-package.json`.

**Why `text.onnx` is rewritten.** The upstream `text` graph takes `text_mask` as `bool`, which the ONNX Runtime
Objective-C binding cannot feed. `rewrite_text_graph.py` renames that input to `text_mask_bool`, adds an int64 graph
input `text_mask` and a `Cast(to=BOOL)` node between them, runs the ONNX checker, and asserts through ONNX Runtime that
`text_ids`, `language` and `text_mask` are all `tensor(int64)`. The cast hands the original consumer the same boolean
mask, so the outputs are expected to equal the original graph's; no test compares them yet.

## Prepare a Core AI package

```bash
tools/neural-speech/.venv/bin/python tools/neural-speech/prepare_coreai_package.py \
  --asset <articulino.aimodel> --config <config.json> \
  --models <onnx-release-dir> --precision int8 \
  --voice <prompt.wav>:<voice-id> --out <package-dir> \
  [--package-id articulino-de-en-coreai] [--function-names text,dit_step,decoder]
```

The Apple Core AI runtime reads a package whose `model-package.json` has `format` `coreai`, `variant` `coreai` and
`runtime.minOsVersion` `27.0`. It reads a graph reference as `<file>` or `<file>#<function>`; this tool always writes
the second form: `speech.graphs.text` is `articulino.aimodel#text` unless `--function-names` renames the three
functions, in the order text, dit_step, decoder. The voices go through the same pipeline as above (`--models`,
`--precision`), so the ONNX release is still needed for them.

```text
<package-dir>/model-package.json        ModelPackage (format coreai, variant coreai, runtime.minOsVersion 27.0)
<package-dir>/config.json               copied from --config; speech.frontend.assets.config
<package-dir>/<asset>.aimodel           copied from --asset, a file or a directory, under its own name
<package-dir>/voices/<voice-id>.safetensors
```

`integrity.checksums` lists the sha256 of every file above except `model-package.json`; a directory asset contributes
each contained file under its path relative to the package. The `.aimodel` comes from the coreai-torch export (spike
0b, see `docs/architecture/decisions/022-core-ai-runtime.md`); this tool does not run the export. The SDK's gated tests
read the directory from `INDERUN_COREAI_MODEL_DIR`.

## Build the demo assets

`build_demo_assets.py` builds the derived files of the Voices lab catalog
(`contracts/fixtures/speech/neural-model-catalog.json`) from the upstream release and the seven committed seeds in
`voice-seeds/` (see its README); no recordings are needed:

```bash
tools/neural-speech/.venv/bin/python tools/neural-speech/build_demo_assets.py --models <onnx-release-dir> \
  --seeds tools/neural-speech/voice-seeds --out <dir>
```

It writes `<out>/text.onnx` (the int8 `text` graph with an int64 `text_mask`), `<out>/<id>.safetensors` for every
seed and `<out>/SHA256SUMS`, and copies the upstream `LICENSE` and `NOTICE` from `--models` into `<out>`
(Apache-2.0 redistribution; the tool refuses when either is missing), and writes each file's `url`, `sha256` and `bytes` into the `articulino-de-en-int8`
entry. The upstream files of that entry (`config.json`, `dit_step.onnx`, `decoder.onnx`) stay pinned by hand to the
Hugging Face revision. The seeds and the catalog's voice ids must match. Last it prints the `gh release create
neural-speech-assets-1 ...` command that lists every output file (licence files included). Its `--notes` state the modification (the
`text_mask` input of `text.onnx` changed from bool to int64, upstream revision, Apache-2.0, NOTICE included) and it
passes `--latest=false`, so the release never becomes the repository's latest. Uploading is the owner's step: the tool never
creates a release, tag or upload. Until the release exists, a demo download of these files answers HTTP 404.

## Time a package on an iPhone

An opt-in check for when a phone is at hand; nothing here runs in CI. Swift package tests cannot run on a physical
device, so the script uses the iOS demo app as the host:

```sh
tools/neural-speech/ios_device_bench.sh --device <udid|name> --package <package-dir> [--rounds 3] [--model-id <id>] [--sdk-version <v>] [--out <file>]
```

It applies `ios-device-bench.patch` (a launch-argument hook in `IndeRunDemoApp.swift`) to the working tree, builds the
demo app in Release, installs it over the demo on the phone, copies the package into the app's Documents, runs two
scenarios of the shared corpus through the public speech API (`first_call_after_prepare`: per round a new engine, a
timed `prepare` and one `speak`; `render_speed`: `de_de_short` and `de_de_long` through `generateSpeech`, one cold
trial plus `--rounds` warm ones), and copies the result back. The result is the shared `inderun-speech-benchmark/1`
JSON report (`harness` `ios_device_bench`, the other five scenarios under `skipped`), written to `--out`, by default
`ios_device_bench-<target>-<device>-<date>.json` in the current directory; the text log is next to it as `<out>.txt`.
`--rounds` defaults to 3, the corpus's trial count. `--model-id` is recorded as the target's `model` (the model catalog
entry id, for example `articulino-de-en-int8`; default is the package id). `--sdk-version` is recorded as `sdkVersion`
(default `dev`). A scenario that fails is listed under `skipped` with its error class (and `details.code`) only, and
keeps none of its samples. The report carries utterance ids, never text, and the
hardware model id (`utsname.machine`) as `device`. The patch is reverted right after the build and again on exit, so
the working tree is unchanged. `xcrun devicectl list devices` shows the device id. The phone must be paired, unlocked
and in Developer Mode, and the demo project needs a signing team. Each sample also records `peakRssDeltaBytes` (a 20
ms `phys_footprint` sampler); the log lines add the thermal state. Reinstall the demo from Xcode to drop the hook from
the phone, and delete the app or its Documents to free the package's space. If the demo's `IndeRunDemoApp.swift`
changes, refresh the patch.

## Voice bundle format

One safetensors file per voice (`prepare_articulino_voice.py` writes it alone, `safetensors_io.py` reads and writes it
without the `safetensors` package). All tensors are batch 1 and C order:

| Tensor           | dtype | Shape                 |
| ---------------- | ----- | --------------------- |
| `voice_tokens`   | F32   | `[1, 32, 768]`        |
| `voice_vector`   | F32   | `[1, 768]`            |
| `voice_cache`    | F32   | `[8, 2, 1, 6, P, 64]` |
| `prompt_latents` | F32   | `[1, 12, 96]`         |
| `letter_rate`    | F32   | `[1]`                 |

`P` is read from `voice_cache`'s shape. `prompt_latents` is the last 12 frames of the first `P` encoder frames.
`letter_rate` is the median speaking rate of six calibration sentences through the `text` graph (no prompt
placeholder, speed 1), used for rate equalisation. `__metadata__`: `format` (`inderun.articulino.voice/1`), `voice_id`,
`source_wav_sha256`, `encoder_sha256`, `voice_sha256`, `upstream_repo`, `tool_version`.

## The host math and its fixture

`articulino_math.py` implements the section "Articulino host math" of the PR 4a plan: letters, durations, frame
condition, flow steps, low shelf (an IIR in float64), peak limit, pause and long-sentence splitting. It is adapted from
`eigenhand/articulino-onnx` (Apache License 2.0). `generate_pipeline_fixture.py` runs it over tiny scripted inputs and
writes `contracts/fixtures/speech/articulino-pipeline.json`, deterministically (seed 260):

```bash
tools/neural-speech/.venv/bin/python tools/neural-speech/generate_pipeline_fixture.py
```

The TypeScript, Swift and Kotlin pipelines run every case of that file; floats match within 1e-4 and int16 samples
within +-1. Regenerating must leave `git diff contracts/fixtures` empty unless the math changed on purpose.

## Licence

Apache License 2.0 applies to the adapted `articulino_math.py` and to the upstream model release; see the model card.
The rest of this tool is MIT like the repository.
