# Neural speech verification record

Timing results for the neural speech providers (`local.onnx.speech.*`), next to the operating system's own voice. Only
real runs go here. A cell that has not been measured says **pending**, and a family that is not built yet says
**deferred**. Nothing in this document is an assumed result. The system voices have their own record in
[system-speech.md](./system-speech.md), the licence record for the models is
[neural-speech-admission.md](./neural-speech-admission.md), and the milestone work is tracked in
[#251](https://github.com/independo-gmbh/inderun/issues/251) and
[#252](https://github.com/independo-gmbh/inderun/issues/252).

These are timing numbers. **No listening scores exist yet.** Nobody has judged the audio of any run below; that is the
quality review's job (PR 12 of #260, not started), and until it lands this record says nothing about how a voice sounds.

## Method

Every run uses the shared corpus in
[`contracts/fixtures/speech/utterance-corpus.json`](../../contracts/fixtures/speech/utterance-corpus.json) and the same
scenarios as the system speech benchmark ([Running the scenarios on another provider](./system-speech.md#running-the-scenarios-on-another-provider)),
plus the corpus's `extendedUtterances` (ids prefixed `ext_`: numbers, dates, money, units, abbreviations, long text and
mixed content), which only the `render_speed` scenario reads. Each run writes one report in the
`inderun-speech-benchmark/1` format
([schema](../../contracts/fixtures/speech/speech-benchmark-report.schema.json)) under
[`docs/verification/reports/`](./reports/). The reports hold the raw samples and the percentiles; the tables below copy
`p50` and `p95` from them and nothing else.

- **Reports.** Six exist: `sdk_tests-apple_system_speech-Mac14-6-2026-11-09.json` (the OS voice on the Mac),
  `sdk_tests-articulino_onnx-int8-Mac14-6-2026-11-09.json` (Articulino on the Mac) and
  `web_voices_lab-articulino-de-en-int8-Chrome-macOS-2026-11-09.json` (Articulino in the web demo) and
  `ios_device_bench-articulino_onnx-int8-iPhone15-4-2026-11-09.json` (Articulino on an iPhone 15), plus the two Core AI
  reports described under [Core AI](#core-ai-apple-fp32): `sdk_tests-articulino_coreai-Mac14-6-2026-11-09.json` and
  `ios_device_bench-articulino_coreai-iPhone15-4-2026-11-09.json`.
- **Mac.** `swift test` on a Mac14,6 (macOS 27.2.0), the `sdk_tests` harness, SDK build `dev+a8ee554`.
  The OS voice and Articulino ran the same scenarios as two separate runs a few minutes apart, one report each.
- **Web.** The Voices lab "Run corpus" button of the web demo (dev server), in Chrome on the same Mac, SDK `0.4.0+dev`, the
  "Automatic" voice (the report has no `voiceId`), with a fresh engine for each scenario. Browsers expose no process memory, so the web report has no
  `peakRssDeltaBytes`.
- **iPhone.** `tools/neural-speech/ios_device_bench.sh` on an iPhone 15 (iPhone15,4, iOS 27.2.0), the
  `ios_device_bench` harness, SDK build `dev+e0a5f0b`, German (`de-DE`) only, three rounds. The harness runs two of the
  seven scenarios, `first_call_after_prepare` and `render_speed`; the other five are listed in the report's `skipped`
  with the reason "not run by the device harness". It has no OS voice run and no extended corpus.
- **Core AI package.** Articulino fp32 as one `articulino.aimodel` asset (`articulino-de-en-coreai`, `coreai`), the
  `neural-speech-assets-2` files, exported as recorded in [ADR 022](../architecture/decisions/022-core-ai-runtime.md#5-conversion-record).
  The report's `target.checksums` carry the three asset checksums. The runs use the Core AI default compute units (the
  spike found fp32 on the GPU; the ANE is not used), and the benchmarks call `prepare` with `allowDownload: true`,
  because specialization needs the app's consent.
- **Model package (ONNX).** Articulino int8 (`articulino-de-en`, `onnx-int8`), built locally with
  `tools/neural-speech/prepare_articulino_package.py`, never committed. The graphs (`dit_step.onnx`, `decoder.onnx`)
  and `config.json` come from the pinned Hugging Face revision `a760ce8d513534111c7679751869fa4c45ef0e54`, checked
  against the upstream `SHA256SUMS`. `text.onnx` and the voices (`de-de-f-1`, `en-us-f-1`) are byte-identical to the
  release `neural-speech-assets-1`. Each report records the checksums of the files that ran in `target.checksums`.
  Execution provider is the ONNX Runtime CPU provider on every platform.
- **Percentiles.** Nearest-rank over the samples of one group, `(scenario, step, utterance)`: sort ascending and take
  index `ceil(q * n) - 1`. A group with one sample has p50 equal to p95. The `n` columns say how many samples stand behind
  a row; most rows have one, two or three, so read p95 as "the slowest sample seen", not as a tail estimate.
- **Units.** Milliseconds rounded to whole numbers (stop latency to one decimal). `RTF` is render time over audio time,
  three decimals; lower is faster, and 1.000 is real time. Peak RSS is the largest memory increase over the
  value at the start of the sample, polled every 20 ms, in MB with MB = 10^6 bytes, one decimal. The memory read is
  `phys_footprint` on Apple platforms and `VmRSS` on Android; the web harness does not measure it. A cell is shown as
  `p50 / p95`.

| Field                                   | Measured from ... to ...                                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `firstChunkMs`                          | The provider receiving the request to the first chunk from the runtime (neural providers only)               |
| `firstAudioMs`                          | The provider receiving the request to the first audible output; the OS voice reports its first word callback |
| `wallMs`                                | Request to the playback ending, so it includes the time the audio takes to play                              |
| `prepareMs`                             | `prepare` called to it resolving                                                                             |
| `stopLatencyMs`                         | `cancel()` called to the `cancelled` ending delivered                                                        |
| `renderMs`, `audioMs`, `realTimeFactor` | Artifact rendering: time to render, length of the audio, and their ratio                                     |
| `peakRssDeltaBytes`                     | Process memory growth during the sample, as above                                                            |

The numbers are single runs on one machine. They are not thresholds, and other devices, voices and engines will differ.
The first `peakRssDeltaBytes` rows include the one-time cost of loading the model into the process, which later rows do
not pay again.

## Matrix

Family by locale by platform by device. **Real** means the cell is covered by a report in this document.

| Family                           | Locale           | Mac14,6 (macOS 27.2)        | Chrome on the same Mac      | iPhone 15 (iPhone15,4)                                                | Android                      | Core AI (fp32)                                            |
| -------------------------------- | ---------------- | --------------------------- | --------------------------- | --------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------- |
| Articulino ONNX int8             | `de-DE`          | Real                        | Real                        | Real (2 of 7 scenarios; the others are not run by the device harness) | pending (no device attached) | Real (Mac, iPhone 15; see [Core AI](#core-ai-apple-fp32)) |
| Articulino ONNX int8             | `en-US`          | Real                        | Real                        | not run (device harness is `de-DE` only)                              | pending (no device attached) | Real (Mac only)                                           |
| Articulino ONNX int8             | `de-AT`          | Real (extended corpus only) | Real (extended corpus only) | not run (device harness is `de-DE` only)                              | pending (no device attached) | Real (Mac, extended corpus only)                          |
| OS voice (`apple_system_speech`) | `de-DE`, `en-US` | Real                        | not run                     | not run                                                               | pending (no device attached) | n/a                                                       |
| Kokoro                           | deferred (#289)  | deferred (#289)             | deferred (#289)             | deferred (#289)                                                       | deferred (#289)              | deferred (#289)                                           |
| Piper                            | deferred (#289)  | deferred (#289)             | deferred (#289)             | deferred (#289)                                                       | deferred (#289)              | deferred (#289)                                           |
| Pocket TTS                       | deferred (#289)  | deferred (#289)             | deferred (#289)             | deferred (#289)                                                       | deferred (#289)              | deferred (#289)                                           |

The Core AI column is the Articulino fp32 asset run through Core AI on the Mac and the iPhone 15 listed in the same row;
it has no Chrome or Android cell because Core AI exists only on iOS and macOS. The OS voice's own pending list is in [system-speech.md](./system-speech.md). The iPhone 15 report comes from the
`ios_device_bench` harness, which runs only `first_call_after_prepare` and `render_speed`; the other five scenarios on
the iPhone are **not run by the device harness**, and they are not pending work. The
[family doc](../architecture/neural-speech-provider-family.md#spike-and-device-findings) also records an earlier iPhone 15
measurement (2026-11-05) from the text harness that preceded this report format; it is not a report in this format. Its
simulator, emulator and desktop rows are not phone measurements.

## Mac (Mac14,6, macOS 27.2.0)

Reports:
`sdk_tests-apple_system_speech-Mac14-6-2026-11-09.json` and
`sdk_tests-articulino_onnx-int8-Mac14-6-2026-11-09.json`. The OS voice column is the same scenario and step on the
system voice, so the neural numbers can be read against it.

### Playback

| Scenario / step                               | Utterance     | OS voice first audio (ms) | Articulino first audio (ms) | OS voice wall (ms) | Articulino wall (ms) | n (OS / Art.) |
| --------------------------------------------- | ------------- | ------------------------- | --------------------------- | ------------------ | -------------------- | ------------- |
| `first_call_cold` / first in process          | `de_de_short` | 4,636 / 4,636             | 1,490 / 1,490               | 6,893 / 6,893      | 3,983 / 3,983        | 1 / 1         |
| `first_call_cold` / new instance              | `de_de_short` | 860 / 861                 | 1,396 / 1,437               | 2,979 / 3,005      | 3,890 / 3,928        | 2 / 2         |
| `first_call_after_prepare` / first in process | `de_de_short` | 412 / 412                 | 219 / 219                   | 2,477 / 2,477      | 2,727 / 2,727        | 1 / 1         |
| `first_call_after_prepare` / new instance     | `de_de_short` | 324 / 363                 | 225 / 239                   | 2,378 / 2,413      | 2,734 / 2,737        | 2 / 2         |
| `repeat_same_voice` / call 1                  | `de_de_short` | 892 / 892                 | 1,379 / 1,379               | 3,037 / 3,037      | 3,884 / 3,884        | 1 / 1         |
| `repeat_same_voice` / call 2                  | `de_de_short` | 45 / 45                   | 226 / 226                   | 2,101 / 2,101      | 2,721 / 2,721        | 1 / 1         |
| `repeat_same_voice` / call 3                  | `de_de_short` | 42 / 42                   | 214 / 214                   | 2,103 / 2,103      | 2,715 / 2,715        | 1 / 1         |
| `repeat_same_voice` / call 4                  | `de_de_short` | 43 / 43                   | 230 / 230                   | 2,101 / 2,101      | 2,714 / 2,714        | 1 / 1         |
| `repeat_same_voice` / call 5                  | `de_de_short` | 52 / 52                   | 236 / 236                   | 2,111 / 2,111      | 2,739 / 2,739        | 1 / 1         |
| `switch_language` / call 1 (en-US)            | `en_us_short` | 504 / 504                 | 1,397 / 1,397               | 2,624 / 2,624      | 4,893 / 4,893        | 1 / 1         |
| `switch_language` / call 2 (de-DE)            | `de_de_short` | 863 / 863                 | 216 / 216                   | 3,007 / 3,007      | 2,712 / 2,712        | 1 / 1         |
| `switch_language` / call 3 (en-US)            | `en_us_short` | 29 / 29                   | 256 / 256                   | 2,070 / 2,070      | 3,745 / 3,745        | 1 / 1         |
| `speak_after_stop` / warm-up                  | `en_us_short` | 460 / 460                 | 1,457 / 1,457               | 2,580 / 2,580      | 4,956 / 4,956        | 1 / 1         |
| `speak_after_stop` / next after stop          | `en_us_short` | 171 / 187                 | 288 / 310                   | 2,230 / 2,239      | 3,791 / 3,801        | 3 / 3         |
| `text_length` / warm-up                       | `de_de_short` | 820 / 820                 | 1,361 / 1,361               | 2,963 / 2,963      | 3,856 / 3,856        | 1 / 1         |
| `text_length` / short                         | `de_de_short` | 42 / 42                   | 245 / 245                   | 2,122 / 2,122      | 2,743 / 2,743        | 1 / 1         |
| `text_length` / long                          | `de_de_long`  | 283 / 283                 | 286 / 286                   | 34,197 / 34,197    | 36,429 / 36,429      | 1 / 1         |

### Prepare and stop

| Scenario / step                                        | Utterance     | Metric          | OS voice (ms) | Articulino (ms) | n (OS / Art.) |
| ------------------------------------------------------ | ------------- | --------------- | ------------- | --------------- | ------------- |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | `prepareMs`     | 947 / 947     | 1,178 / 1,178   | 1 / 1         |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | `prepareMs`     | 636 / 695     | 1,155 / 1,313   | 2 / 2         |
| `speak_after_stop` / stop                              | `en_us_long`  | `stopLatencyMs` | 0.5 / 0.8     | 32.9 / 33.6     | 3 / 3         |

### Peak memory growth

| Scenario / step                                        | Utterance     | OS voice (MB) | Articulino (MB) |
| ------------------------------------------------------ | ------------- | ------------- | --------------- |
| `first_call_cold` / first in process                   | `de_de_short` | 8.8 / 8.8     | 253.7 / 253.7   |
| `first_call_cold` / new instance                       | `de_de_short` | 0.3 / 0.7     | 2.8 / 116.8     |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | 0.2 / 0.2     | 0.7 / 0.7       |
| `first_call_after_prepare` / first in process          | `de_de_short` | 0.3 / 0.3     | 0.6 / 0.6       |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | 0.2 / 0.2     | 0.4 / 0.6       |
| `first_call_after_prepare` / new instance              | `de_de_short` | 0.0 / 0.0     | 0.8 / 0.9       |
| `repeat_same_voice` / call 1                           | `de_de_short` | 0.1 / 0.1     | 0.9 / 0.9       |
| `repeat_same_voice` / call 2                           | `de_de_short` | 0.1 / 0.1     | 0.2 / 0.2       |
| `repeat_same_voice` / call 3                           | `de_de_short` | 0.0 / 0.0     | 0.3 / 0.3       |
| `repeat_same_voice` / call 4                           | `de_de_short` | 0.0 / 0.0     | 0.1 / 0.1       |
| `repeat_same_voice` / call 5                           | `de_de_short` | 0.0 / 0.0     | 0.1 / 0.1       |
| `switch_language` / call 1 (en-US)                     | `en_us_short` | 0.1 / 0.1     | 1.4 / 1.4       |
| `switch_language` / call 2 (de-DE)                     | `de_de_short` | 0.2 / 0.2     | 0.1 / 0.1       |
| `switch_language` / call 3 (en-US)                     | `en_us_short` | 0.1 / 0.1     | 0.4 / 0.4       |
| `speak_after_stop` / warm-up                           | `en_us_short` | 0.1 / 0.1     | 1.4 / 1.4       |
| `speak_after_stop` / next after stop                   | `en_us_short` | 0.1 / 0.3     | 0.5 / 0.5       |
| `text_length` / warm-up                                | `de_de_short` | 0.0 / 0.0     | 39.3 / 39.3     |
| `text_length` / short                                  | `de_de_short` | 0.1 / 0.1     | 0.1 / 0.1       |
| `text_length` / long                                   | `de_de_long`  | 1.1 / 1.1     | 2.6 / 2.6       |
| `render_speed` / cold                                  | `de_de_short` | 0.1 / 0.1     | 39.4 / 39.4     |
| `render_speed` / warm                                  | `de_de_short` | 0.1 / 0.2     | 0.0 / 0.1       |
| `render_speed` / cold                                  | `de_de_long`  | 4.7 / 4.7     | 4.9 / 4.9       |
| `render_speed` / warm                                  | `de_de_long`  | 1.7 / 3.4     | 1.5 / 2.0       |

### Render speed

| Scenario / step       | Utterance     | OS audio (ms)   | OS render (ms) | OS RTF        | Art. audio (ms) | Art. render (ms) | Art. RTF      | n (OS / Art.) |
| --------------------- | ------------- | --------------- | -------------- | ------------- | --------------- | ---------------- | ------------- | ------------- |
| `render_speed` / cold | `de_de_short` | 1,986 / 1,986   | 1,010 / 1,010  | 0.509 / 0.509 | 2,350 / 2,350   | 1,289 / 1,289    | 0.549 / 0.549 | 1 / 1         |
| `render_speed` / warm | `de_de_short` | 1,986 / 1,986   | 906 / 913      | 0.456 / 0.460 | 2,350 / 2,350   | 96 / 101         | 0.041 / 0.043 | 3 / 3         |
| `render_speed` / cold | `de_de_long`  | 33,539 / 33,539 | 1,784 / 1,784  | 0.053 / 0.053 | 36,000 / 36,000 | 1,351 / 1,351    | 0.038 / 0.038 | 1 / 1         |
| `render_speed` / warm | `de_de_long`  | 33,539 / 33,539 | 1,663 / 1,816  | 0.050 / 0.054 | 36,000 / 36,000 | 1,353 / 1,561    | 0.038 / 0.043 | 3 / 3         |

### Extended corpus, Articulino

Each row is one sample (`p50` = `p95`). The Mac and web audio lengths differ by a few tens of milliseconds on some
rows.

| Utterance                    | Mac audio (ms) | Mac render (ms) | Mac RTF | Web audio (ms) | Web render (ms) | Web RTF |
| ---------------------------- | -------------- | --------------- | ------- | -------------- | --------------- | ------- |
| `ext_de_de_numbers_cardinal` | 6,950          | 248             | 0.036   | 6,470          | 710             | 0.110   |
| `ext_de_de_numbers_decimal`  | 8,670          | 299             | 0.035   | 8,110          | 790             | 0.097   |
| `ext_de_at_numbers_house`    | 5,790          | 208             | 0.036   | 5,430          | 635             | 0.117   |
| `ext_de_de_dates_range`      | 8,790          | 313             | 0.036   | 8,350          | 773             | 0.093   |
| `ext_de_at_dates_jaenner`    | 8,630          | 299             | 0.035   | 8,070          | 730             | 0.090   |
| `ext_en_us_dates`            | 4,710          | 172             | 0.036   | 4,510          | 409             | 0.091   |
| `ext_de_de_money_total`      | 12,990         | 462             | 0.036   | 12,190         | 1,151           | 0.094   |
| `ext_de_at_money_small`      | 7,310          | 254             | 0.035   | 6,910          | 617             | 0.089   |
| `ext_en_us_money`            | 4,430          | 164             | 0.037   | 4,150          | 419             | 0.101   |
| `ext_de_de_units_speed`      | 8,470          | 290             | 0.034   | 7,870          | 711             | 0.090   |
| `ext_de_de_units_kitchen`    | 7,510          | 264             | 0.035   | 7,110          | 676             | 0.095   |
| `ext_en_us_units`            | 4,870          | 178             | 0.037   | 4,630          | 395             | 0.085   |
| `ext_de_de_abbr_titles`      | 7,510          | 261             | 0.035   | 6,990          | 575             | 0.082   |
| `ext_de_at_abbr_address`     | 8,820          | 322             | 0.036   | 8,100          | 711             | 0.088   |
| `ext_en_us_abbr`             | 8,890          | 331             | 0.037   | 8,490          | 748             | 0.088   |
| `ext_de_de_long_morning`     | 41,100         | 1,471           | 0.036   | 38,780         | 3,392           | 0.087   |
| `ext_de_at_long_travel`      | 35,710         | 1,238           | 0.035   | 33,230         | 2,803           | 0.084   |
| `ext_en_us_long_garden`      | 37,430         | 1,305           | 0.035   | 35,390         | 3,017           | 0.085   |
| `ext_de_de_mixed_product`    | 7,390          | 242             | 0.033   | 6,950          | 585             | 0.084   |
| `ext_de_de_mixed_meeting`    | 5,750          | 204             | 0.035   | 5,350          | 453             | 0.085   |
| `ext_de_at_mixed_music`      | 5,750          | 209             | 0.036   | 5,390          | 488             | 0.091   |
| `ext_en_us_mixed`            | 6,670          | 236             | 0.035   | 6,310          | 457             | 0.072   |

## Web (Chrome on macOS)

Report: `web_voices_lab-articulino-de-en-int8-Chrome-macOS-2026-11-09.json`. Compare it with the Articulino columns of
the Mac tables; the OS voice has no web run here. The report has no `peakRssDeltaBytes`.

### Playback

| Scenario / step                               | Utterance     | First chunk (ms) | First audio (ms) | Wall (ms)       | n   |
| --------------------------------------------- | ------------- | ---------------- | ---------------- | --------------- | --- |
| `first_call_cold` / first in process          | `de_de_short` | 1,323 / 1,323    | 1,514 / 1,514    | 3,466 / 3,466   | 1   |
| `first_call_cold` / new instance              | `de_de_short` | 575 / 580        | 766 / 775        | 2,710 / 2,716   | 2   |
| `first_call_after_prepare` / first in process | `de_de_short` | 169 / 169        | 359 / 359        | 2,302 / 2,302   | 1   |
| `first_call_after_prepare` / new instance     | `de_de_short` | 161 / 162        | 349 / 354        | 2,292 / 2,292   | 2   |
| `repeat_same_voice` / call 1                  | `de_de_short` | 566 / 566        | 759 / 759        | 2,700 / 2,700   | 1   |
| `repeat_same_voice` / call 2                  | `de_de_short` | 176 / 176        | 364 / 364        | 2,309 / 2,309   | 1   |
| `repeat_same_voice` / call 3                  | `de_de_short` | 214 / 214        | 402 / 402        | 2,347 / 2,347   | 1   |
| `repeat_same_voice` / call 4                  | `de_de_short` | 173 / 173        | 359 / 359        | 2,304 / 2,304   | 1   |
| `repeat_same_voice` / call 5                  | `de_de_short` | 179 / 179        | 370 / 370        | 2,314 / 2,314   | 1   |
| `switch_language` / call 1 (en-US)            | `en_us_short` | 711 / 711        | 904 / 904        | 4,001 / 4,001   | 1   |
| `switch_language` / call 2 (de-DE)            | `de_de_short` | 179 / 179        | 364 / 364        | 2,309 / 2,309   | 1   |
| `switch_language` / call 3 (en-US)            | `en_us_short` | 249 / 249        | 439 / 439        | 3,541 / 3,541   | 1   |
| `speak_after_stop` / warm-up                  | `en_us_short` | 645 / 645        | 841 / 841        | 3,938 / 3,938   | 1   |
| `speak_after_stop` / next after stop          | `en_us_short` | 249 / 250        | 439 / 439        | 3,542 / 3,542   | 3   |
| `text_length` / warm-up                       | `de_de_short` | 589 / 589        | 780 / 780        | 2,723 / 2,723   | 1   |
| `text_length` / short                         | `de_de_short` | 181 / 181        | 369 / 369        | 2,315 / 2,315   | 1   |
| `text_length` / long                          | `de_de_long`  | 209 / 209        | 398 / 398        | 34,112 / 34,112 | 1   |

### Prepare and stop

| Scenario / step                                        | Metric          | Web (ms)  | n   |
| ------------------------------------------------------ | --------------- | --------- | --- |
| `first_call_after_prepare` / prepare, first in process | `prepareMs`     | 405 / 405 | 1   |
| `first_call_after_prepare` / prepare, new instance     | `prepareMs`     | 396 / 406 | 2   |
| `speak_after_stop` / stop                              | `stopLatencyMs` | 0.3 / 0.6 | 3   |

### Render speed

| Scenario / step       | Utterance     | Audio (ms)      | Render (ms)   | RTF           | n   |
| --------------------- | ------------- | --------------- | ------------- | ------------- | --- |
| `render_speed` / cold | `de_de_short` | 2,110 / 2,110   | 629 / 629     | 0.298 / 0.298 | 1   |
| `render_speed` / warm | `de_de_short` | 2,110 / 2,110   | 175 / 178     | 0.083 / 0.084 | 3   |
| `render_speed` / cold | `de_de_long`  | 33,880 / 33,880 | 2,697 / 2,697 | 0.080 / 0.080 | 1   |
| `render_speed` / warm | `de_de_long`  | 33,880 / 33,880 | 3,453 / 3,584 | 0.102 / 0.106 | 3   |

The extended corpus rows for the web run are in the Mac extended table above.

## iPhone 15 (iPhone15,4, iOS 27.2.0)

Report: `ios_device_bench-articulino_onnx-int8-iPhone15-4-2026-11-09.json`. Only `first_call_after_prepare` and
`render_speed` ran; the other five scenarios are in the report's `skipped` ("not run by the device harness"). German
only, three rounds, Articulino int8 with the ONNX Runtime CPU provider. There is no OS voice run on the phone, so these
tables have no comparison column; read them against the Articulino columns of the Mac tables. The numbers are one phone
in one session and are not a thermal or battery study.

### Playback

| Scenario / step                               | Utterance     | First chunk (ms) | First audio (ms) | Wall (ms)     | Peak RSS growth (MB) | n   |
| --------------------------------------------- | ------------- | ---------------- | ---------------- | ------------- | -------------------- | --- |
| `first_call_after_prepare` / first in process | `de_de_short` | 222 / 222        | 322 / 322        | 2,719 / 2,719 | 20.9 / 20.9          | 1   |
| `first_call_after_prepare` / new instance     | `de_de_short` | 91 / 119         | 189 / 217        | 2,594 / 2,614 | 3.6 / 3.8            | 2   |

### Prepare

| Scenario / step                                        | Utterance     | `prepareMs` (ms) | Peak RSS growth (MB) | n   |
| ------------------------------------------------------ | ------------- | ---------------- | -------------------- | --- |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | 486 / 486        | 318.8 / 318.8        | 1   |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | 227 / 233        | 24.9 / 75.8          | 2   |

### Render speed

| Scenario / step       | Utterance     | Audio (ms)      | Render (ms)   | RTF           | Peak RSS growth (MB) | n   |
| --------------------- | ------------- | --------------- | ------------- | ------------- | -------------------- | --- |
| `render_speed` / cold | `de_de_short` | 2,350 / 2,350   | 302 / 302     | 0.128 / 0.128 | 89.2 / 89.2          | 1   |
| `render_speed` / warm | `de_de_short` | 2,350 / 2,350   | 71 / 72       | 0.030 / 0.030 | 0.4 / 0.5            | 3   |
| `render_speed` / cold | `de_de_long`  | 36,000 / 36,000 | 991 / 991     | 0.028 / 0.028 | 1.4 / 1.4            | 1   |
| `render_speed` / warm | `de_de_long`  | 36,000 / 36,000 | 1,023 / 1,040 | 0.028 / 0.029 | 0.0 / 21.4           | 3   |

## Core AI (Apple, fp32)

Articulino through the Apple Core AI runtime ([ADR 022](../architecture/decisions/022-core-ai-runtime.md)), the fp32
`articulino.aimodel` of `neural-speech-assets-2`, read against the ONNX Runtime int8 run on the same device. Both sides
are Articulino and the same pipeline; they differ in runtime, precision (fp32 against int8) and the graphs. The tables
below are copied from the four reports and checked against them. Every cell copies `p50 / p95` from the reports; `n/a`
means the report has no such metric.

**Headline.** On both devices, Core AI fp32 is slower than ONNX int8 inside the pipeline: warm render speed is an RTF of
0.064 to 0.096 on the Mac and 0.063 to 0.100 on the iPhone 15, against 0.038 to 0.041 and 0.028 to 0.030 for ONNX int8.
The phone's first `prepare` (specialize, load and warm-up) takes 9,246 ms; the Mac's does not (see below). The spike
record measured three things about this asset: Core AI compiles once per new input shape, the asset is fp32, and the
work runs on the GPU (the ANE is not used). This record does not attribute the pipeline numbers to any one of them.

- **Mac (Mac14,6, macOS 27.2.0).** `sdk_tests`, SDK build `dev+22c5d26`, all seven scenarios plus the extended corpus
  (the extended rows are in the report and are not tabulated). **The Mac's Core AI specialization cache was already
  warm from the export spike, so its `prepareMs` excludes a cold specialization**; read the Mac prepare rows as "load
  and warm up", not as the first-install cost. The spike measured a cold specialization of 1.22 s on the same Mac
  (ADR 022).
- **iPhone 15 (iPhone15,4, iOS 27.2.0).** `ios_device_bench`, SDK build `dev+52f3b35`, German only, three rounds, the
  two scenarios the device harness runs. The first `prepare` in the process includes the cold specialization of the
  asset on the phone.
- **Disk.** Specialization writes about 262 MB per specialized asset per app into the Core AI cache (spike, default
  options, on the Mac); the cache is purgeable and the OS may drop it, which makes the package `not_prepared` again.
  The spike measured it once, on the Mac; it was not measured on the phone.
- **Consent.** The benchmarks call `prepare` with `allowDownload: true`: without it, `prepare` is skipped on a device
  whose specialization cache is empty.
- **Not measured.** Cold-specialization time on the Mac. There are no listening scores
  here, so none of this says how the Core AI audio sounds; the spike's numeric match to ONNX fp32 is in ADR 022.

### Mac (Mac14,6, macOS 27.2.0)

Reports: `sdk_tests-articulino_coreai-Mac14-6-2026-11-09.json` against
`sdk_tests-articulino_onnx-int8-Mac14-6-2026-11-09.json`.

#### Playback

| Scenario / step                               | Utterance     | Core AI first audio (ms) | ONNX int8 first audio (ms) | Core AI wall (ms) | ONNX int8 wall (ms) | n (Core AI / ONNX) |
| --------------------------------------------- | ------------- | ------------------------ | -------------------------- | ----------------- | ------------------- | ------------------ |
| `first_call_cold` / first in process          | `de_de_short` | 3,028 / 3,028            | 1,490 / 1,490              | 5,527 / 5,527     | 3,983 / 3,983       | 1 / 1              |
| `first_call_cold` / new instance              | `de_de_short` | 2,196 / 2,224            | 1,396 / 1,437              | 4,702 / 4,724     | 3,890 / 3,928       | 2 / 2              |
| `first_call_after_prepare` / first in process | `de_de_short` | 666 / 666                | 219 / 219                  | 3,168 / 3,168     | 2,727 / 2,727       | 1 / 1              |
| `first_call_after_prepare` / new instance     | `de_de_short` | 610 / 638                | 225 / 239                  | 3,108 / 3,150     | 2,734 / 2,737       | 2 / 2              |
| `repeat_same_voice` / call 1                  | `de_de_short` | 2,156 / 2,156            | 1,379 / 1,379              | 4,653 / 4,653     | 3,884 / 3,884       | 1 / 1              |
| `repeat_same_voice` / call 2                  | `de_de_short` | 438 / 438                | 226 / 226                  | 2,938 / 2,938     | 2,721 / 2,721       | 1 / 1              |
| `repeat_same_voice` / call 3                  | `de_de_short` | 423 / 423                | 214 / 214                  | 2,933 / 2,933     | 2,715 / 2,715       | 1 / 1              |
| `repeat_same_voice` / call 4                  | `de_de_short` | 411 / 411                | 230 / 230                  | 2,921 / 2,921     | 2,714 / 2,714       | 1 / 1              |
| `repeat_same_voice` / call 5                  | `de_de_short` | 435 / 435                | 236 / 236                  | 2,939 / 2,939     | 2,739 / 2,739       | 1 / 1              |
| `switch_language` / call 1 (en-US)            | `en_us_short` | 2,163 / 2,163            | 1,397 / 1,397              | 5,672 / 5,672     | 4,893 / 4,893       | 1 / 1              |
| `switch_language` / call 2 (de-DE)            | `de_de_short` | 738 / 738                | 216 / 216                  | 3,228 / 3,228     | 2,712 / 2,712       | 1 / 1              |
| `switch_language` / call 3 (en-US)            | `en_us_short` | 486 / 486                | 256 / 256                  | 3,985 / 3,985     | 3,745 / 3,745       | 1 / 1              |
| `speak_after_stop` / warm-up                  | `en_us_short` | 2,195 / 2,195            | 1,457 / 1,457              | 5,688 / 5,688     | 4,956 / 4,956       | 1 / 1              |
| `speak_after_stop` / next after stop          | `en_us_short` | 408 / 424                | 288 / 310                  | 3,907 / 3,933     | 3,791 / 3,801       | 3 / 3              |
| `text_length` / warm-up                       | `de_de_short` | 2,653 / 2,653            | 1,361 / 1,361              | 5,160 / 5,160     | 3,856 / 3,856       | 1 / 1              |
| `text_length` / short                         | `de_de_short` | 417 / 417                | 245 / 245                  | 2,926 / 2,926     | 2,743 / 2,743       | 1 / 1              |
| `text_length` / long                          | `de_de_long`  | 840 / 840                | 286 / 286                  | 36,966 / 36,966   | 36,429 / 36,429     | 1 / 1              |

#### Prepare and stop

| Scenario / step                                        | Utterance     | Metric          | Core AI (ms)  | ONNX int8 (ms) | n (Core AI / ONNX) |
| ------------------------------------------------------ | ------------- | --------------- | ------------- | -------------- | ------------------ |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | `prepareMs`     | 1,539 / 1,539 | 1,178 / 1,178  | 1 / 1              |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | `prepareMs`     | 1,520 / 1,528 | 1,155 / 1,313  | 2 / 2              |
| `speak_after_stop` / stop                              | `en_us_long`  | `stopLatencyMs` | 28.9 / 32.9   | 32.9 / 33.6    | 3 / 3              |

#### Render speed

| Scenario / step       | Utterance     | Core AI audio (ms) | ONNX int8 audio (ms) | Core AI render (ms) | ONNX int8 render (ms) | Core AI RTF   | ONNX int8 RTF | n (Core AI / ONNX) |
| --------------------- | ------------- | ------------------ | -------------------- | ------------------- | --------------------- | ------------- | ------------- | ------------------ |
| `render_speed` / cold | `de_de_short` | 2,350 / 2,350      | 2,350 / 2,350        | 2,469 / 2,469       | 1,289 / 1,289         | 1.051 / 1.051 | 0.549 / 0.549 | 1 / 1              |
| `render_speed` / warm | `de_de_short` | 2,350 / 2,350      | 2,350 / 2,350        | 225 / 232           | 96 / 101              | 0.096 / 0.099 | 0.041 / 0.043 | 3 / 3              |
| `render_speed` / cold | `de_de_long`  | 35,960 / 35,960    | 36,000 / 36,000      | 4,460 / 4,460       | 1,351 / 1,351         | 0.124 / 0.124 | 0.038 / 0.038 | 1 / 1              |
| `render_speed` / warm | `de_de_long`  | 35,960 / 35,960    | 36,000 / 36,000      | 2,303 / 2,310       | 1,353 / 1,561         | 0.064 / 0.064 | 0.038 / 0.043 | 3 / 3              |

#### Peak memory growth

| Scenario / step                                        | Utterance     | Core AI (MB)  | ONNX int8 (MB) |
| ------------------------------------------------------ | ------------- | ------------- | -------------- |
| `first_call_cold` / first in process                   | `de_de_short` | 380.1 / 380.1 | 253.7 / 253.7  |
| `first_call_cold` / new instance                       | `de_de_short` | 35.3 / 323.4  | 2.8 / 116.8    |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | 25.4 / 25.4   | 0.7 / 0.7      |
| `first_call_after_prepare` / first in process          | `de_de_short` | 12.8 / 12.8   | 0.6 / 0.6      |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | 25.5 / 25.5   | 0.4 / 0.6      |
| `first_call_after_prepare` / new instance              | `de_de_short` | 11.8 / 12.7   | 0.8 / 0.9      |
| `render_speed` / cold                                  | `de_de_short` | 320.4 / 320.4 | 39.4 / 39.4    |
| `render_speed` / cold                                  | `de_de_long`  | 160.8 / 160.8 | 4.9 / 4.9      |

### iPhone 15 (iPhone15,4, iOS 27.2.0)

Reports: `ios_device_bench-articulino_coreai-iPhone15-4-2026-11-09.json` against
`ios_device_bench-articulino_onnx-int8-iPhone15-4-2026-11-09.json`. Only `first_call_after_prepare` and `render_speed`
ran.

#### Playback

| Scenario / step                               | Utterance     | Core AI first audio (ms) | ONNX int8 first audio (ms) | Core AI wall (ms) | ONNX int8 wall (ms) | n (Core AI / ONNX) |
| --------------------------------------------- | ------------- | ------------------------ | -------------------------- | ----------------- | ------------------- | ------------------ |
| `first_call_after_prepare` / first in process | `de_de_short` | 2,045 / 2,045            | 322 / 322                  | 4,457 / 4,457     | 2,719 / 2,719       | 1 / 1              |
| `first_call_after_prepare` / new instance     | `de_de_short` | 603 / 639                | 189 / 217                  | 3,000 / 3,037     | 2,594 / 2,614       | 2 / 2              |

The warm-up in `prepare` runs each function once at the smallest shapes (N = L = F = 2), not at the sentence's shapes, so the first sentence after `prepare` (2,045 ms to first audio) is still slower than a later one (603 ms): it loads the first sentence's own shapes.

#### Prepare and stop

| Scenario / step                                        | Utterance     | Metric      | Core AI (ms)  | ONNX int8 (ms) | n (Core AI / ONNX) |
| ------------------------------------------------------ | ------------- | ----------- | ------------- | -------------- | ------------------ |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | `prepareMs` | 9,246 / 9,246 | 486 / 486      | 1 / 1              |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | `prepareMs` | 536 / 3,703   | 227 / 233      | 2 / 2              |

#### Render speed

| Scenario / step       | Utterance     | Core AI audio (ms) | ONNX int8 audio (ms) | Core AI render (ms) | ONNX int8 render (ms) | Core AI RTF   | ONNX int8 RTF | n (Core AI / ONNX) |
| --------------------- | ------------- | ------------------ | -------------------- | ------------------- | --------------------- | ------------- | ------------- | ------------------ |
| `render_speed` / cold | `de_de_short` | 2,350 / 2,350      | 2,350 / 2,350        | 1,020 / 1,020       | 302 / 302             | 0.434 / 0.434 | 0.128 / 0.128 | 1 / 1              |
| `render_speed` / warm | `de_de_short` | 2,350 / 2,350      | 2,350 / 2,350        | 235 / 257           | 71 / 72               | 0.100 / 0.109 | 0.030 / 0.030 | 3 / 3              |
| `render_speed` / cold | `de_de_long`  | 35,960 / 35,960    | 36,000 / 36,000      | 8,102 / 8,102       | 991 / 991             | 0.225 / 0.225 | 0.028 / 0.028 | 1 / 1              |
| `render_speed` / warm | `de_de_long`  | 35,960 / 35,960    | 36,000 / 36,000      | 2,260 / 2,268       | 1,023 / 1,040         | 0.063 / 0.063 | 0.028 / 0.029 | 3 / 3              |

#### Peak memory growth

| Scenario / step                                        | Utterance     | Core AI (MB)  | ONNX int8 (MB) |
| ------------------------------------------------------ | ------------- | ------------- | -------------- |
| `first_call_after_prepare` / prepare, first in process | `de_de_short` | 396.2 / 396.2 | 318.8 / 318.8  |
| `first_call_after_prepare` / first in process          | `de_de_short` | 34.1 / 34.1   | 20.9 / 20.9    |
| `first_call_after_prepare` / prepare, new instance     | `de_de_short` | 277.8 / 291.6 | 24.9 / 75.8    |
| `first_call_after_prepare` / new instance              | `de_de_short` | 11.9 / 23.5   | 3.6 / 3.8      |
| `render_speed` / cold                                  | `de_de_short` | 300.5 / 300.5 | 89.2 / 89.2    |
| `render_speed` / cold                                  | `de_de_long`  | 6.4 / 6.4     | 1.4 / 1.4      |

## Reproduce

Each harness writes the `inderun-speech-benchmark/1` report (`contracts/fixtures/speech/speech-benchmark-report.schema.json`)
and names it `<harness>-<target>-<device>-<date>.json`, with the device name reduced to `[A-Za-z0-9._-]`.

- **Mac and Swift SDK tests.** `INDERUN_SPEECH_BENCHMARK=1 INDERUN_SPEECH_BENCHMARK_MODEL_DIR=<package dir>
INDERUN_SPEECH_BENCHMARK_MODEL_ID=articulino-de-en-int8 INDERUN_SPEECH_BENCHMARK_OUT=<dir> swift test --filter
SpeechBenchmarkTests`. Without `MODEL_DIR` only the OS voice runs. `INDERUN_SPEECH_BENCHMARK_SDK_VERSION` sets
  `sdkVersion` (default `dev`).
- **Core AI on the Mac.** As the Mac run above with `INDERUN_COREAI_MODEL_DIR=<Core AI package dir>`, which adds the
  `articulino_coreai` target (macOS 27); `INDERUN_SPEECH_BENCHMARK_MODEL_ID_COREAI` sets its model id. The package comes
  from `prepare_coreai_package.py` around the `neural-speech-assets-2` files.
- **Core AI on the iPhone.** The same `ios_device_bench.sh` command with a Core AI package; the hook builds the Core AI
  provider for a `format: "coreai"` package (see `tools/neural-speech/README.md`).
- **Android.** `cd android && ./gradlew :inderun-kotlin:connectedAndroidTest
-Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true` plus, as needed,
  `-Pandroid.testInstrumentationRunnerArguments.speechBenchmarkModelDir=<package dir on the device>`,
  `...speechBenchmarkModelId=articulino-de-en-int8`, `...speechBenchmarkOut=<name>` and `...speechBenchmarkSdkVersion`.
  The reports land in `<name>` under the app's external files directory; the log prints each absolute path
  (`INDERUN-BENCH-OUT`, `INDERUN-BENCH-REPORT`). Fetch them with `adb pull` before the test app is uninstalled.
- **iPhone.** `tools/neural-speech/ios_device_bench.sh --device <udid|name> --package <package dir> --model-id
articulino-de-en-int8` (see `tools/neural-speech/README.md`). It runs two of the seven scenarios.
- **Browser.** In the Voices lab (`VITE_INDERUN_VOICES_LAB=1`), download the model, choose the voice ("Automatic"
  leaves `voiceId` out of the report) and press "Run corpus"; the report downloads when the run ends. "Export report"
  downloads the last run again, with the rendered audio attached when asked. A dev-server build records
  `sdkVersion` with a `+dev` suffix.

## Pending

- **iPhone 15 (iPhone15,4):** the other five scenarios (`first_call_cold`, `repeat_same_voice`, `switch_language`, `speak_after_stop`, `text_length`), the OS voice and `en-US` are not run by the device harness.
- **Android:** pending, no device attached.
- **OS voice in the browser:** not run.
- **Core AI:** cold specialization time on the Mac (its cache was warm). No demo links a Core AI runtime path, so the Voices lab shows the catalog entry as unavailable in all three demos.
- **Kokoro, Piper, Pocket TTS:** deferred (#289).
- **Supertonic 3:** not integrated. Its upstream repositories are archived and unmaintained since September 2026 (owner decision, 2026-11-09, #277).
- **Listening scores:** none yet (PR 12).
