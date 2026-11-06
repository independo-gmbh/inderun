# Articulino voice seeds

The seven `*.seed.wav` files are the committed seeds of the demo voices. Each is one neutral sentence (or two)
synthesized from a first-hop voice bundle; `build_demo_assets.py` turns every seed into the shippable bundle
`<id>.safetensors` (hop 2: seed -> upstream `encoder` + `voice` graphs), which is deterministic. The bundles derive
from Independo's consented speakers. The original recordings, their excerpts and the first-hop bundles are not in
this repository and are never committed.

## Recipe

1. Window: a 6-8 s span of a recording, 24 kHz mono, normalised to -20 dBFS RMS over voiced frames (frames above
   -40 dBFS), then peak-limited to 0.95.
2. Hop 1: window -> upstream `encoder` + `voice` graphs -> bundle A (comparison only, not committed).
3. Seed: one neutral sentence synthesized from bundle A (fp32 graphs, the noise seed in the table, speed 1.0) ->
   `<id>.seed.wav`.
4. Hop 2: seed -> `<id>.safetensors` (bundle B, the shippable voice), built by `build_demo_assets.py`.

`letter_rate` is letters per second and `P` the number of prompt frames (125 means 5 s or more of prompt).
"Pause(s) shortened": the recordings read phrases with pauses of 0.5-1.7 s, so no 6-8 s span of them is free of
pauses longer than 300 ms. For those windows, each silent run (below -35 dBFS) longer than 300 ms was cut to 300 ms,
with a 5 ms fade at each cut; no speech was changed. "Window noise-reduced": the window got a gentle stationary noise
reduction before hop 1, because the recording's room noise carried into the synthesized voice. The noise is a NumPy
`default_rng(seed)` stream, drawn per flow step and per sentence, in order.

## Voices

| id | Speaker | Locale | Window length s | Gain dB | letter_rate (hop 1 / hop 2) | P (hop 1 / hop 2) | Seed s | Noise seed | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `de-at-m-1` | man, Austrian German | de-AT | 7.92 | +11.5 | 16.98 / 17.53 | 125 / 125 | 5.64 | 0 | window noise-reduced before hop 1; 3 pause(s) shortened |
| `de-at-m-1-alt` | man, Austrian German (same speaker as de-at-m-1, window 3: more Austrian "Tag") | de-AT | 7.80 | +10.1 | 16.96 / 18.14 | 125 / 125 | 5.64 | 0 | window noise-reduced before hop 1; 2 pause(s) shortened |
| `de-at-m-2` | man, Austrian German | de-AT | 7.12 | +1.7 | 18.97 / 18.28 | 125 / 125 | 5.28 | 0 | 4 pause(s) shortened |
| `de-de-f-1` | woman, Germany German | de-DE | 7.52 | -1.7 | 17.33 / 16.40 | 125 / 125 | 5.40 | 0 | 2 pause(s) shortened |
| `de-de-f-2` | woman, Germany German | de-DE | 7.92 | +1.2 | 18.43 / 19.00 | 125 / 125 | 5.20 | 0 | 4 pause(s) shortened |
| `de-de-f-3` | woman, Germany German | de-DE | 6.00 | -3.2 | 18.03 / 16.45 | 125 / 125 | 5.72 | 0 |  |
| `en-us-f-1` | woman, American English | en-US | 7.40 | -0.2 | 19.20 / 18.03 | 125 / 125 | 7.39 | 0 | 4 pause(s) shortened |

Graphs: upstream `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX` at revision
`a760ce8d513534111c7679751869fa4c45ef0e54`. Voice graphs are `int8/encoder.onnx` and `int8/voice.onnx`, which upstream
ships as fp16. `letter_rate` comes from `int8/text.onnx`, as `prepare_articulino_voice.py` measures it. Seed synthesis
used the fp32 `text`, `dit_step` and `decoder` graphs.

## Rebuild

```bash
tools/neural-speech/.venv/bin/python tools/neural-speech/build_demo_assets.py --models <onnx-release-dir> \
  --seeds tools/neural-speech/voice-seeds --out <dir>
```
