# System speech verification record

Results for the system speech providers. Only real runs go here. A check that has not been run says **pending** and
gives the steps; it never carries an assumed result. Automated coverage is listed in
[providers.md](../architecture/providers.md#demos--tests-per-family) and
[speech-conformance.md](../speech-conformance.md).

Simulators, emulators and scripted browsers prove routing, callbacks and cancellation. They do not prove what a person
hears, so listening checks need a real device.

## Method

Every automated run below uses the shared corpus in
[`contracts/fixtures/speech/utterance-corpus.json`](../../contracts/fixtures/speech/utterance-corpus.json): German
(`de-AT`, `de-DE`) and English (`en-US`) utterances covering short text, punctuation, numerals, dates, times and
currency, and long text; one locale no voice speaks, which must be refused; three renders in a row of the same
utterance; and a stop 1.5 s into a long utterance followed by a new one. Every run uses `local_required`. The texts are
synthetic, and the tests log only ids and measurements, so nothing a user typed reaches CI output.

- **Apple:** `AppleSystemSpeechCorpusTests` (`swift test`, or `xcodebuild test` on a simulator or a device).
- **Android:** `AndroidSystemSpeechCorpusTest` (`cd android && ./gradlew :inderun-kotlin:connectedAndroidTest`), with
  the traces read by `adb logcat -d -s IndeRunCorpus:I`. CI runs it on every Android change; see
  [docs/ci.md](../ci.md#real-speech-on-an-emulator).
- **Web:** no automated real-browser run. Headless browsers list no voices, so Web results come from manual runs only.

Each run prints one `INDERUN-TRACE` line per utterance. What the fields measure (every `firstAudioMs` and time-to-first-word
recorded in this document was taken before the origin moved to the provider's request receipt, and will read slightly
higher on the next run):

| Field | Measured from … to … |
| --- | --- |
| `bytes`, `sampleRate`, `durationMs` | The WAV artifact as read back through `readArtifact`; the duration is the engine's, checked against the byte count |
| `synthesisMs` | `generateSpeech` called to returned, routing included |
| `firstAudioMs` | The provider starting to handle the request to the platform's first word callback (`PlaybackOutput.timing.firstAudioMs`) |
| `stopLatencyMs` | `cancel()` called to the `cancelled` ending delivered |
| `fallbackCalls` | Calls into a second registered speech provider; must stay 0 after audio started |

A locale with no installed voice is reported in the run's `skipped` list. It never counts as passed. The numbers below
are single runs on the machines named. They are not thresholds, and other devices, voices and engines will differ.

## Apple (`apple_system_speech`)

Recorded 2026-11-02 with `AppleSystemSpeechArtifactTests` against the real `AVSpeechSynthesizer`:

| Environment | Check | Result |
| --- | --- | --- |
| macOS host (`swift test`) | `en-US` utterance finishes; a long one ends `cancelled` on `cancel()` | Passed |
| macOS host (`swift test`) | `generateSpeech` returns a WAV artifact that reads back with the right header, size and duration | Passed |
| iPhone 17 Simulator (`xcodebuild test`) | Same two checks | Passed |

The tests observe callbacks and bytes. Nobody listened to the output, and the simulator says nothing about a real audio
route.

Recorded 2026-11-03 with `AppleSystemSpeechCorpusTests` on a macOS 27.2 host (`swift test`, Xcode 27.2), compact voices
Anna (`de-DE`) and Samantha (`en-US`). Every corpus utterance rendered; none was skipped. `de-AT` resolved to the `de-DE`
voice, because the host has no Austrian voice and the default locale match is by language. All WAVs were 16-bit mono PCM
at 22,050 Hz with locality `on_device`, and each was gone after `disposeArtifact`.

| Utterance | Bytes | Audio | `synthesisMs` |
| --- | --- | --- | --- |
| `de_at_short` (→ `de-DE`) | 91,048 | 2,064 ms | 1,501 |
| `de_at_regional` (→ `de-DE`) | 395,858 | 8,975 ms | 1,229 |
| `de_de_short` | 87,614 | 1,986 ms | 1,051 |
| `de_de_punctuation` | 328,278 | 7,443 ms | 1,235 |
| `de_de_numerals` | 542,122 | 12,292 ms | 1,062 |
| `de_de_long` | 1,479,134 | 33,539 ms | 1,689 |
| `en_us_short` | 86,750 | 1,966 ms | 616 |
| `en_us_punctuation` | 346,772 | 7,862 ms | 646 |
| `en_us_numerals` | 466,848 | 10,585 ms | 660 |
| `en_us_long` | 1,193,544 | 27,063 ms | 907 |

| Scenario | Result |
| --- | --- |
| `unsupported_locale` through `speak` and `generateSpeech` | Both refused with `CapabilityMismatch`, no attempt made |
| `de_de_short` and `en_us_short`, three renders each | Three distinct artifacts each, identical sizes; disposing one left the others readable |
| `en_us_long` stopped after 1.5 s, with a second speech provider registered | One `cancelled` ending; stop delivered in under 1 ms; the second provider was never called; `committed: true` |
| `en_us_short` right after the stop | Finished `stop` on the same synthesizer; `firstAudioMs` 38, audio 1,999 ms |

**Fixed during this run: long text was cut off.** The first pass rendered `de_de_long` to 12,244 ms and `en_us_long` to
14,000 ms, although the same texts play for about 34 s and 27 s. `write(_:toBufferCallback:)` sends an empty buffer at
each of its internal chunk boundaries, not only at the end, and the provider ended the artifact at the first one. Every
per-file check passed, because the truncated WAV was well-formed. The latency benchmark below exposed it by comparing
playback and render durations. The provider now ends a render on `didFinish`, which the synthesizer also sends after a
written utterance's last buffer, and both corpus suites now fail when a long utterance's audio is not proportionate to
its text. The table above is from after the fix.

**Fixed during this run:** releasing a provider shortly after a stop crashed the test process (`EXC_BAD_ACCESS` in the
`TextToSpeech` framework, on the main queue). The system delivers the stopped utterance's callbacks some time after
`stopSpeaking`, and they reached a synthesizer or delegate that had been freed. It reproduced in most runs of two real
playback tests in a row. A released provider now retires its synthesizer and last playback session instead of freeing
them, stops the synthesizer and frees both on the main queue five seconds later; six repeated runs afterwards did not
crash. `testDiscardedProvidersReleaseTheirSynthesizersAfterStoppedSpeech` creates, stops and drops four providers in a
row and checks that every retired synthesizer is freed, so recreating providers does not hold synthesizers for the life
of the process. An application that creates its provider once never hit this, but one that recreated providers after
stopping speech could have.

Recorded 2026-11-02 on a physical iPhone, with a listener. With no audio session category set, `speak()` ran and nothing
was audible until Silent mode was turned off and the media volume raised. With the demo setting `.playback`, speech was
audible with Silent mode on.

Recorded 2026-11-02 on the same iPhone, from the tap to the first `willSpeakRangeOfSpeechString` callback, with the
German text in `ios/SampleApps/IndeRunDemo`, on the Anna compact voice:

| Case                                       | Time to first word |
| ------------------------------------------ | ------------------ |
| New synthesizer per utterance, every tap   | 1407 and 1441 ms   |
| Shared synthesizer, first tap with a voice | 1870 ms            |
| Shared synthesizer, later taps             | 159 and 161 ms     |

Voice loading caused the gap, not the audio session: pre-activating the session changed nothing. Directly on
`AVSpeechSynthesizer`, a voice stayed loaded after switching to another voice and back (77 and 116 ms). A silent
`write(_:toBufferCallback:)` took about 815 ms and left a first word at about 360 to 400 ms, against about 1115 ms cold.

**Pending, on a physical iPhone, with a listener:**

0. Run `AppleSystemSpeechCorpusTests` on the device (`xcodebuild test -scheme IndeRun-Package -destination
   'platform=iOS,id=<udid>' -only-testing:IndeRunTests/AppleSystemSpeechCorpusTests`) and record its traces like the
   macOS table above.

1. Run `ios/SampleApps/IndeRunDemo`. Speak `de-AT` and `de-DE` text; note which voice and region spoke.
2. Pick a language with no installed voice; confirm a refusal and no sound.
3. Speak short and long text; press **Stop** mid-utterance; note the stop latency. Press **Speak** right after **Stop**
   and confirm the new utterance plays, because both use one synthesizer.
   Call `prepare()` before the first tap; compare the first word against the times above, and confirm it is silent with
   music playing.
4. Turn on airplane mode, speak with the app's default `local_required` policy, and confirm it still speaks.
5. Speak while a call or timer interrupts; confirm the outcome is `failed` with `speech_interrupted` and nothing resumes.
6. Background the app during speech and return; record what happens.
7. Turn on VoiceOver and speak; record how the two overlap.

## Android (`android_system_speech`)

Recorded 2026-11-02 on the `rk_api36` emulator (Android 16, Google APIs, headless) with the system's Google TTS engine,
driving `android/inderun-demo-app`. Each run used `local_required`, the demo's default, except the artifact.

| Check | Result |
| --- | --- |
| `en-US` playback through `speak()` | Finished: `stop`, `android_system_speech`, locality `on_device` |
| `de-DE` and `de-AT` playback | Refused by routing with `CapabilityMismatch`: this image has no installed German voice that satisfies `local_required`. Nothing played |
| `en-US` long utterance, Stop after 3 s | Ended `cancelled` with one outcome; no failure logged |
| `generateSpeech`, `en-US` | `audio/wav`, RIFF header, 98,902 bytes, 2,059.5 ms, read back, then disposed. `cache/inderun-speech` empty afterwards |

The run observed callbacks, outcomes and bytes. Nobody listened: the emulator was headless, so this says nothing about
what reached a speaker.

Recorded 2026-11-03 with `AndroidSystemSpeechCorpusTest` on the same `rk_api36` emulator (Android 16, Google TTS
`googletts.google-speech-apk_20241125.02_p2`), which by then had a German voice installed from the ADR 019 run below.
All four tests passed and nothing was skipped. The engine reported its default voices `de-DE-language` and
`en-US-language`; `de-AT` resolved to `de-DE`. All WAVs were 24,000 Hz PCM with locality `on_device`, and
`cache/inderun-speech` was empty after every render.

| Utterance | Bytes | Audio | `synthesisMs` |
| --- | --- | --- | --- |
| `de_at_short` (→ `de-DE`) | 112,438 | 2,342 ms | 856 |
| `de_at_regional` (→ `de-DE`) | 499,456 | 10,404 ms | 277 |
| `de_de_short` | 115,466 | 2,405 ms | 165 |
| `de_de_punctuation` | 477,568 | 9,948 ms | 261 |
| `de_de_numerals` | 630,994 | 13,145 ms | 274 |
| `de_de_long` | 1,817,516 | 37,864 ms | 1,388 |
| `en_us_short` | 98,800 | 2,057 ms | 163 |
| `en_us_punctuation` | 349,326 | 7,277 ms | 214 |
| `en_us_numerals` | 486,160 | 10,127 ms | 243 |
| `en_us_long` | 1,343,530 | 27,989 ms | 542 |

| Scenario | Result |
| --- | --- |
| `unsupported_locale` through `speak` and `generateSpeech` | Both refused with `CapabilityMismatch`, no attempt made |
| `de_de_short` and `en_us_short`, three renders each | Three distinct artifacts each; sizes within 2 bytes; disposing one left the others readable |
| `en_us_long` stopped after 1.5 s, with a second speech provider registered | One `cancelled` ending; stop delivered in 4 ms; the second provider was never called; `committed: true` |
| `en_us_short` right after the stop | Finished `stop`; `firstAudioMs` 57, audio 2,092 ms |

The emulator had `-audio none`, so this proves callbacks and bytes, not sound.

Recorded 2026-11-02 on the same emulator, for ADR 019. `listVoices` for `de-DE` returned 9 voices, all `not_prepared`,
which the provider used to hide. Picking `de-de-x-nfh-local` ran `prepare` with `allowDownload`. A speak about 2 s later
finished `stop` with that voice and `on_device`, and within 16 s the voice no longer read `not_prepared`. The emulator has
no audio output, so this proves completion, not sound.

Recorded 2026-11-10 on a physical Pixel 9 Pro (Tensor G4, Android 17, API 37), `android_system_speech`, SDK build
`dev+475015f`, from `SpeechBenchmarkTest`; the figures are the `p50` of
`docs/verification/reports/sdk_tests-android_system_speech-Google-Pixel-9-Pro-2026-11-10.json` and read like the two
tables above (the emulator keeps its own). The same instrumented suite ran on the phone with 10 tests passing and 1
skipped, the skip being the opt-in benchmark. The full tables with `p95` are in
[the neural speech record](./neural-speech.md#pixel-9-pro-tensor-g4-android-17-api-37). Nobody listened to these runs.

| Scenario | Step | `firstAudioMs` median (n) | Other |
| --- | --- | --- | --- |
| `first_call_cold` | First in process | 736 (1) | |
| | New instance | 293 (2) | |
| `first_call_after_prepare` | `prepare()` | | 203 ms first in process, 212 after |
| | Then the first utterance | 273 first in process, 282 after | |
| `repeat_same_voice` | Call 1 | 301 (1) | |
| | Calls 2 to 5 | 256 to 329 | |
| `switch_language` | `en-US`, first | 670 | |
| | Then `de-DE` | 308 | |
| | Back to `en-US` | 294 | |
| `speak_after_stop` | Stop | | `stopLatencyMs` 27.5 median, 33.3 p95 (3) |
| | Next utterance | 292 (3) | |
| `text_length` | Short, warm | 294 | |
| | Long, warm | 574 | |
| `render_speed` | Short, cold / warm | | 399 / 269 ms for 2,405 ms of audio; RTF 0.166 / 0.112 |
| | Long, cold / warm | | 1,429 / 1,412 ms for 37,822 ms of audio; RTF 0.038 / 0.037 |

On the phone the warm first-word latency (`firstAudioMs`) is 256 to 329 ms, where the emulator showed 25 to 45 ms, and
the stop latency (`stopLatencyMs`) is about 28 ms, where the emulator showed about 8 ms. No cause was investigated.

**Pending, on a physical Android device, with a listener** (only the benchmark above has run; step 0 is the
instrumented-suite run, whose `IndeRunCorpus` traces were not recorded):

0. Run `./gradlew :inderun-kotlin:connectedAndroidTest` with the phone connected, and record its traces like the
   emulator table above. The suite passed on the Pixel 9 Pro (above); the traces are not recorded.

1. Install a German voice. Run `inderun-demo-app`; speak `de-AT` and `de-DE` and note which voice and region spoke.
2. With a network-only voice as the only match, speak under the demo's `local_required` and confirm a refusal.
3. Press **Stop speaking** mid-utterance; note the stop latency and confirm the speech does not restart.
4. Turn on airplane mode and confirm network voices are not chosen.
4a. With a voice the engine lists as not installed: speak with it required and confirm `not_ready`. Repeat the emulator
   record below on a physical phone, with a listener.
5. Repeat one playback and one **Synthesize** with a second TTS engine, if one is available, and record what differs.

## Web (`web_system_speech`)

Recorded 2026-11-02 with `packages/inderun-web-demo` in desktop Chrome 156 on macOS, using real mouse clicks.

| Check | Result |
| --- | --- |
| Voice discovery | Chrome listed 199 voices. Recorded before `listVoices` returned every voice; **pending** re-run with the voice picker |
| `de-DE` playback through `speak()` | Finished: `stop`, `de-DE`, `web_system_speech`, locality `unknown` |
| Long `de-DE` utterance, Stop after 2 s | Ended `cancelled`; `speechSynthesis.speaking` and `pending` both false afterwards |
| A new utterance right after `cancel()`, three times, direct on `speechSynthesis` | Started and finished each time; the stopped one reported `interrupted` |
| Scripted click with no user gesture | Chrome refused; the panel reported `Unavailable` from `not-allowed`, and the app kept working |

Browser support, as tested. A browser not listed as tested has not been run, whatever its API suggests.

| Environment | Status |
| --- | --- |
| Chrome 156, macOS | Tested |
| Edge, Firefox, Safari, Android Chrome, iOS Safari | **Pending.** In each: open the demo, press Speak in `de-DE` and `en-US`, then press Stop mid-utterance, and record outcome, voice count and locality |
| A browser without `speechSynthesis` | Covered by unit tests only: capability refusal, no runtime type error |

The Chrome run was on a machine with audio output, but no listener recorded what was heard.

## Latency scenarios

Which provider to use, and whether to call `prepare()`, depends on how speech starts, not only on how it sounds. The
`benchmark` section of the corpus holds seven scenarios, each one question a developer asks before adopting a
provider:

| Scenario | Question |
| --- | --- |
| `first_call_cold` | How long does the very first utterance take to start, on a new provider instance? |
| `first_call_after_prepare` | Does `prepare()` make that first utterance start sooner, and what does `prepare()` cost? |
| `repeat_same_voice` | Do later utterances on the same voice start faster than the first? |
| `switch_language` | What does changing language, and so voice, between calls cost? |
| `speak_after_stop` | How quickly does Stop take effect, and does the next utterance start normally? |
| `text_length` | Does the first word wait for the whole text? A streaming engine starts as fast on long text as on short. |
| `render_speed` | How long does `generateSpeech()` take, cold and warm, and what is the real-time factor (render time ÷ audio duration)? |

They are opt-in, because they play audio for minutes:

- **Apple:** `INDERUN_SPEECH_BENCHMARK=1 swift test --filter SpeechBenchmarkTests`, or prefix
  `TEST_RUNNER_INDERUN_SPEECH_BENCHMARK=1` to `xcodebuild test` for a simulator or device.
- **Android:** `./gradlew :inderun-kotlin:connectedAndroidTest
  -Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true`, then `adb logcat -d -s IndeRunBenchmark:I`. The same run writes the JSON reports to the test app's external files directory
  (`speechBenchmarkOut`); `connectedAndroidTest` uninstalls the test app when it ends, so pass
  `-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true` and fetch them with `adb pull`; see
  [the neural speech record](./neural-speech.md#reproduce).

Each sample is one `INDERUN-BENCH` line, and each step one `INDERUN-BENCH-SUMMARY` line with the median, maximum and
count. Cold and warm calls are never pooled. `firstAudioMs` is the platform's first word callback (the numbers recorded
below were taken before the origin moved to the provider's request receipt and will read slightly higher on the next
run); `wallMs` is
`speak()` called to its ending, so it includes routing and the audio itself. The runs below have one to five samples per
step on one machine each. They show the shape of each provider, not a number to plan with.

Recorded 2026-11-03, `apple_system_speech`, macOS 27.2 host, compact voices Anna (`de-DE`) and Samantha (`en-US`):

| Scenario | Step | `firstAudioMs` median (n) | Other |
| --- | --- | --- | --- |
| `first_call_cold` | First in process | 1,160 (1) | |
| | New instance | 1,140 (2) | |
| `first_call_after_prepare` | `prepare()` | | 631 to 723 ms |
| | Then the first utterance | 334 to 419 (3) | |
| `repeat_same_voice` | Call 1 | 1,016 (1) | |
| | Calls 2 to 5 | 51 to 56 | |
| `switch_language` | `en-US`, first | 486 | |
| | Then `de-DE`, first time | 907 | |
| | Back to `en-US` | 35 | |
| `speak_after_stop` | Stop | | `cancel()` to ending under 1 ms (3) |
| | Next utterance | 33 (3) | |
| `text_length` | Short, warm | 51 | |
| | Long, warm | 298 | |
| `render_speed` | Short, cold / warm | | 1,047 / 913 ms for 1,986 ms of audio; RTF 0.53 / 0.46 |
| | Long, cold / warm | | 1,715 / 1,704 ms for 33,539 ms of audio; RTF 0.05 |

Recorded 2026-11-03, `android_system_speech`, `rk_api36` emulator, Google TTS, voices `de-DE-language` and
`en-US-language`:

| Scenario | Step | `firstAudioMs` median (n) | Other |
| --- | --- | --- | --- |
| `first_call_cold` | First in process | 381 (1) | |
| | New instance | 27 (2) | |
| `first_call_after_prepare` | `prepare()` | | 333 ms first in process, 71 ms after |
| | Then the first utterance | 375 first in process, 45 after | |
| `repeat_same_voice` | Call 1 | 382 (1) | |
| | Calls 2 to 5 | 25 to 43 | |
| `switch_language` | `en-US`, first | 72 | |
| | Then `de-DE` | 337 | |
| | Back to `en-US` | 26 | |
| `speak_after_stop` | Stop | | `cancel()` to ending 7.9 ms median, 9.2 max (3) |
| | Next utterance | 24 (3) | |
| `text_length` | Short, warm | 45 | |
| | Long, warm | 54 | |
| `render_speed` | Short, cold / warm | | 834 / 82 ms for 2,405 ms of audio; RTF 0.35 / 0.03 |
| | Long, cold / warm | | 657 / 630 ms for 37,859 ms of audio; RTF 0.02 |

What these runs say:

- **The first utterance on a voice is the slow one, on both platforms.** On Apple it is about 1.1 s to the first word,
  then about 50 ms. On Android about 0.4 s, then 25 to 45 ms.
- **On Apple every new provider instance is cold again;** on Android it is not, because the TTS engine is a system
  service that keeps the voice loaded. Create the Apple provider once.
- **`prepare()` helps on Apple:** about 0.7 s spent ahead of time took the first word from about 1.1 s to about 0.35 s,
  still short of a warm call. On Android, once the engine is warm, `prepare()` is nearly free.
- **A new language costs a voice load once:** about 0.9 s on Apple and 0.3 s on Android the first time; switching back
  is cheap.
- **Stop is immediate** on both, and the next utterance starts warm.
- **Both system engines stream:** a long text starts within 0.3 s on Apple and 54 ms on Android. A provider that has to
  synthesize the whole text first would show a first word that grows with the text here.
- **Rendering is faster than real time on both,** but on Apple every `generateSpeech()` pays about 0.8 s even when
  warm, because each render uses a new synthesizer that loads its voice again. Android's warm render of a short text
  takes 82 ms.

**Pending:** the same runs on a physical iPhone, and several trials per step and a second voice per language on both the
emulator and the physical Android phone (one Pixel 9 Pro run, 2026-11-10, is recorded above).

### Running the scenarios on another provider

The scenarios use only the public speech API, so they compare any provider that declares `text_to_speech`. Each
platform's benchmark has a list of targets, a provider and optionally one pinned voice, in `SpeechBenchmarkTests.swift`
and `SpeechBenchmarkTest.kt`. Adding an entry adds a column to the tables above; the scenarios do not change. A scenario
whose delivery a target does not declare is reported as `unsupported` for it, and a target without a voice for the
locale as `unavailable`.

The neural speech providers run these scenarios too; their results, next to the operating system's voice, are in
[neural-speech.md](./neural-speech.md).

Candidates this is meant for, none of which IndeRun ships today:

- a neural model on ONNX Runtime or Core ML, wrapped as a `text_to_speech` provider;
- a custom voice built as an `AVSpeechSynthesisProviderAudioUnit` extension: the system lists it like any other voice,
  so it is the existing `apple_system_speech` target with that voice pinned;
- a second Android TTS engine, or a cloud speech provider, for comparison.

Each needs the provider admission decision first; the neural candidates are evaluated in #260. Keep the scenarios and
the corpus unchanged when comparing, so the numbers stay comparable.

## Speech controls

Device checks for rate, pitch and volume ([ADR 025](../architecture/decisions/025-speech-controls.md)). The declared
ranges (rate and pitch 0.5 to 2, volume 0 to 1, Web states only on `localService: true` voices) are conservative choices
made without device evidence. Every item below is **not yet run**; no result is recorded until someone runs it on the
named platform, and an unrun item never counts as passed. Automated tests prove the values handed to the platform and
the records reported, not what a person hears.

### How to run

Nothing below is a result. Fill a table cell only after you ran that check on a real device, and put in it the date,
device model, OS or browser version, the voice id or name, and the result (`passed`, or `failed: <what you saw>`).
A simulator, an emulator or a desktop browser is not device evidence. Do not edit a cell you did not run.

**Launch the demos.**

- Web: `pnpm install`, then `pnpm build` once (the demo imports the built `@independo/inderun-web` and the WASM route
  core, so rebuild after any SDK change), then `pnpm --filter @independo/inderun-web-demo dev`. To open it on a
  phone, `pnpm --filter @independo/inderun-web-demo dev -- --host` and use the printed LAN address. Open the **Speech**
  panel.
- Apple: open `ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj` in Xcode, scheme `IndeRunDemo`, pick your iPhone,
  set a signing team, Run. Open the **Speech** tab.
- Android: `cd android && ./gradlew :inderun-demo-app:installDebug` with the phone attached (USB debugging on), or
  `:inderun-demo-app:assembleDebug` and install the APK under
  `android/inderun-demo-app/build/outputs/apk/debug/`.
  The first build compiles the Rust route core and needs the NDK (see `android/README.md`). Open the Speech section.

**What the three demos share.** A text box (default "Der Bus kommt in fünf Minuten."), a language choice (`de-AT`,
`de-DE`, `en-US`), a voice picker (default Automatic), and a "Speech controls" block with one checkbox and slider each
for Rate, Pitch and Volume plus a "Require rate" checkbox. A control is off until you tick it; an off control sends
nothing. A control is disabled, with the reason beside it, when the picked voice does not offer it. Each row's note
reads `Speak: available` or `Generate: available` (or why not, or `outside min-max`). The slider ends are the range
`listVoices({ includeControls: true })` reported for that voice. Picking a voice or a language resets the sliders. The
sliders are continuous, so you cannot hit 0.75 or 1.5 exactly: use the nearest value and write the value shown in the
label (Android, Apple) or readout (Web). **Speak** plays and **Stop** cancels. Android and Apple call the artifact
action **Synthesize**; Web calls it **Generate audio**. After each action the status line shows the finish reason,
resolved locale, voice, provider, locality, one entry per control (`speech.speakingRate applied 1.5 (method)` or
`... not applied: <reason>`) and, for **Speak**, `first word N ms` (`firstAudioMs`). Copy that line into your notes.
Android and Apple route speech `Local Only`; Web speaks through the browser's `speechSynthesis`.

**Per check** (rows in table order).

1. Rate, `de-AT` or `de-DE`. Pick `de-AT` (if the device has no such voice, the status line names the resolved locale:
   record that it fell back to `de-DE`). Tick only Rate, set about 0.75, Speak, then about 1.5, then 1.0. Listen: slow,
   fast, normal. Record the voice and the resolved locale.
2. Pitch, `de-DE`. Same with only Pitch at about 0.8, 1.25 and 1.0. Listen for lower, higher, normal.
3. `en-US`. Choose English, then set Rate, Pitch and Volume 0.5 one at a time and all together. Each change must be
   audible and the status line must list the control as applied.
4. Volume 0.5. Note the device media volume first, Speak at Volume 1.0 and at 0.5 (same text), listen for the quieter
   one, and confirm the device volume setting is unchanged afterwards. Volume applies to **Speak** only.
5. Artifact (Android, Apple). Tick Rate, set about 0.75, press Synthesize, then about 1.5. The status line shows the
   audio duration (`N ms audio`): slower speech must be longer. The Android and Apple demos only read the file back and
   do not play it, so the duration and the `applied` records (rate, and pitch if ticked) are your evidence. Web has no
   artifact (record "not applicable" as the table says). `generateSpeech` has no volume option on any SDK, and a raw
   request that carries `delivery.playback` on an artifact is refused by validation before anything runs; unit and
   fixture tests cover that, so there is nothing to hear here.
6. Ranges. For Rate and Pitch (and Volume on Speak), tick the control, drag the slider fully to the minimum, Speak,
   then fully to the maximum, Speak. Record the two ends shown, that the control is `applied` at both, and that the
   platform did not clamp or reject (audible change at each end). The ranges themselves are only visible as the slider
   ends and the `outside` note; the demos do not print the raw `listVoices` entry. *Gap:* the demos cannot send a value
   outside the reported range (they never send it), so "the platform refuses just past the end" is not testable.
7. Required control refused, falls back. *Gap, not drivable from the demos:* the only required control is "Require
   rate", and the demo sends a rate only when it is inside the voice's reported range, so no request is ever one the
   platform refuses. Each demo also registers a single speech provider, so there is no first provider to hear stay
   silent and no fallback provider. The Voices lab (opt-in, neural plus OS voice) has no control sliders. Closest
   manual method: tick Require rate at the range ends (check 6) and confirm it is applied with no fallback line; the
   refusal path itself needs a harness that registers a second provider or a voice whose range is wrong, which is
   outside the demos. Record "not drivable from the demo" with what you did run; do not mark it passed.
8. Without controls, system rate and pitch. Leave every control unticked. First set the system speech setting away
   from normal (Android: Settings, Text-to-speech output, speech rate and pitch; Apple: Settings, Accessibility,
   Spoken Content, Speaking Rate; Web: the browser or OS offers none, so record the browser/OS and what you heard).
   Speak: it must follow your system setting. Then reset the setting.
9. No leak between utterances. Speak with Rate about 1.5, then untick Rate and Speak again: the second must not be
   fast. On Android, with a non-default system rate set (check 8), the second must return to that rate, not to 1.0.
   Repeat with Pitch.
10. Cancel mid-speech. Use a longer text, tick Rate (and Pitch), Speak, press Stop after a second. The status line
    must read `cancelled` and still list the control records. The line also shows `stopped in N ms` on all three.
11. Latency. Same voice, same text, restart nothing between runs. Speak 5 times with all controls off, then 5 times
    with Rate (and Pitch) ticked, and note `first word N ms` each time (first run after launch separately, since it
    loads the voice). Record both medians.
12. Offline. Use an on-device voice (Android and Apple demos route `Local Only`; on Web pick a voice whose controls are
    not disabled, since Web states only `localService: true` voices). Turn on airplane mode (Web: keep the page open,
    then go offline), repeat checks 1 to 3, and compare the audible result and the status records with online.
13. `prefersAssistiveTechnologySettings` (Apple only). *Gap:* the demo does not show or set this flag, and the status
    line does not print it. Indirect method: set a non-default Spoken Content rate in Accessibility, tick Rate at 1.0
    and Speak. If controls are applied correctly the speech is at normal speed, not at your accessibility rate with
    the control stacked on it. Record it as the indirect result only, not as direct proof of the flag.

**Not drivable from the demos, summary.** Check 7 (forced refusal and fallback), the out-of-range edge of check 6,
and the direct flag in check 13. Automated tests cover their logic; on a device, record what you ran and leave the rest
"not drivable from the demo".

| Check | Apple | Android | Web |
| --- | --- | --- | --- |
| `de-AT` voice, or its `de-DE` fallback: rate 0.75 and 1.5 are audibly slower and faster than 1 | not yet run | not yet run | not yet run |
| `de-DE` voice: pitch 0.8 and 1.25 are audibly lower and higher than 1 | not yet run | not yet run | not yet run |
| English (`en-US`) voice: rate, pitch and volume (0.5) change as requested | not yet run | not yet run | not yet run |
| Volume 0.5 attenuates the utterance and leaves the device volume unchanged | not yet run | not yet run | not yet run |
| An artifact (`generateSpeech`) honours rate and pitch (it takes no volume; see How to run, check 5) | not yet run | not yet run | not applicable (no artifact) |
| `listVoices({ includeControls: true })` ranges match what the platform accepts at both ends | not yet run | not yet run | not yet run |
| A required control the platform refuses ends before commit and falls back, with no sound from the first provider | not yet run | not yet run | not yet run |
| Without controls, speech uses the user's own system rate and pitch (Android: Settings, Text-to-speech output, set away from normal) | not yet run | not yet run | not yet run |
| Repeated utterances: a rate set on one does not leak into the next without controls (Android restores the user's system default, not 1.0) | not yet run | not yet run | not yet run |
| A utterance cancelled mid-speech keeps the reported control records | not yet run | not yet run | not yet run |
| Latency: `firstAudioMs` with and without controls on the same voice, same text | not yet run | not yet run | not yet run |
| Offline: controls on an on-device voice behave the same in airplane mode | not yet run | not yet run | not yet run |
| `prefersAssistiveTechnologySettings` off when a control is applied (accessibility speech settings not applied on top) | not yet run | not applicable | not applicable |

## Packaging

Measured 2026-11-03 from local release builds.

| Platform | What | Size |
| --- | --- | --- |
| Android | `inderun-system-speech-providers-release.aar` | 75,789 bytes |
| Web | `dist/providers/system-speech/*.js` of `@independo/inderun-web` | 18,759 bytes, 5,204 gzipped |
| Apple | `apple_system_speech` inside `IndeRunAppleProviders` | **Pending**: not measured separately |

None of the providers bundles a voice or a model: every voice is the platform's own.

## Why no other provider

The system providers on Apple and Android return real, retrievable `audio/wav` for every corpus utterance, so #251 needs
no cloud or neural provider, and none is proposed here. Neural on-device models are evaluated separately, behind the
provider admission rule, in #260.

## Published release smoke check

The steps in [release.md](../release.md#release-smoke-check) were run for 0.5.0-rc.21 (the core packages) and, for the
Capacitor bridge, on a plugin branch built against 0.5.0. Both are below. No physical device was used and nobody
listened. The physical-device launch records ([template](./website-launch-template.md)) are still owed, and so is a
smoke run of the stable 0.5.0 packages and of the published Capacitor package.

### Core packages, 0.5.0-rc.21

Recorded 2026-11-10 as the release smoke check of 0.5.0-rc.21, installing the published packages (npm, SwiftPM `exact`, Maven Central) into fresh scratch apps and running the README quick start. Nobody listened: all three were headless or simulated.

| Platform | Environment | Check | Result |
| --- | --- | --- | --- |
| Web (`@independo/inderun-web` 0.5.0-rc.21) | Playwright headless Chromium 158 on macOS, 180 voices listed | `speak()` from a click, `cancel()` after 1 s | Ended `cancelled`, `web_system_speech`, locality `unknown`, no error |
| Apple (`IndeRun` 0.5.0-rc.21, SwiftPM `exact`) | iPhone 17 Simulator, iOS 26.4 | `speak()` | Finished `stop`, `apple_system_speech`, `on_device`, Samantha, first word 1,855 ms |
| | | `generateSpeech()` | `audio/wav`, 95,132 bytes, 2,156 ms, RIFF/WAVE header read back; a read after `disposeArtifact` was refused |
| Android (`inderun-kotlin` + `inderun-system-speech-providers` 0.5.0-rc.21, Maven Central) | `rk_api36` emulator (Android 16, Google TTS, no audio) | `speak()` | Finished `STOP`, `android_system_speech`, OnDevice, first word 135 ms |
| | | `generateSpeech()` | `audio/wav`, 117,100 bytes, 2,439 ms, RIFF/WAVE header read back; a read after dispose was refused |

The Android app needed Kotlin 2.4 on the consumer side, as `android/README.md` documents.

### Capacitor bridge

Recorded 2026-11-10 with the Capacitor bridge's consumer smoke app (`@independo/capacitor-inderun` 1.2.0, branch
`feat/speech-api`, commit `7726bb9eff8200e84045c87fa6e92960c5096300`, pinned to inderun 0.5.0), a scratch copy of its
`example-app` with a temporary autorun hook. This is a plugin branch commit, not the published prerelease package.
Simulator, emulator and headless browser only; nobody listened to any output.

| Platform | Environment | Result |
| --- | --- | --- |
| iOS | iPhone 18 Pro Simulator, iOS 27.0, Xcode 27.2 | Passed: capabilities, 68 voices (1 for `de`), speak and cancel at 300 ms (`cancelled`), speak to `stop`, `generateSpeech` WAV (84,586 B, 22,050 Hz, `artifact_not_found` after dispose), local text run answered by Apple Foundation Models, `close()` then `run()` fails `engine_closed` |
| iOS | Same, neural Articulino (`articulino-de-en-int8`, 113 MB, `app_managed`) | Passed: download, `prepare()` completed (checksums verified), speak served by `local.onnx.speech.apple:articulino-de-en-int8` (`stop`, first audio 245 ms), WAV 24,000 Hz, reconfigure to system speech only still speaks |
| Android | AVD `rk_api36` (Pixel 7 Pro profile), Android 16 / API 36, arm64 | Passed: capabilities (ML Kit GenAI unavailable, system speech available), 472 voices (189 need the network), speak and cancel, speak to `stop` (first audio 120 ms), `generateSpeech` WAV (119,398 B, 24,000 Hz, `artifact_not_found` after dispose), local text run refused `CapabilityMismatch` (no AICore), `close()` then `run()` fails `engine_closed` |
| Android | Same, neural Articulino | Passed: download, `prepare()` completed, neural speak (`stop`, first audio 211 ms), WAV 24,000 Hz, reconfigure to system speech only still speaks |
| Web | Playwright Chromium 156 (headless) on macOS | Capabilities, 180 voices, local text run refused (`CapabilityMismatch`), `generateSpeech` refused as expected, `close()` then `run()` fails `engine_closed`. Under `local_required` speak is refused (de-DE offered only through voices counted as off-device); with no privacy constraint and a simulated click, speak and cancel at 300 ms (`cancelled`) and speak to `stop` pass |

Observation: `prepare()` delivered no `preparation_progress` events on either platform, only the terminal event.

