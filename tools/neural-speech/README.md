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

## Voice bundle format

One safetensors file per voice (`prepare_articulino_voice.py` writes it alone, `safetensors_io.py` reads and writes it
without the `safetensors` package). All tensors are batch 1 and C order:

| Tensor           | dtype | Shape               |
| ---------------- | ----- | ------------------- |
| `voice_tokens`   | F32   | `[1, 32, 768]`      |
| `voice_vector`   | F32   | `[1, 768]`          |
| `voice_cache`    | F32   | `[8, 2, 1, 6, P, 64]` |
| `prompt_latents` | F32   | `[1, 12, 96]`       |
| `letter_rate`    | F32   | `[1]`               |

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
