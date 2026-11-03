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

Each run prints one `INDERUN-TRACE` line per utterance. What the fields measure:

| Field | Measured from … to … |
| --- | --- |
| `bytes`, `sampleRate`, `durationMs` | The WAV artifact as read back through `readArtifact`; the duration is the engine's, checked against the byte count |
| `synthesisMs` | `generateSpeech` called to returned, routing included |
| `firstAudioMs` | The provider handing the utterance to the platform to its first word callback (`PlaybackOutput.firstAudioMs`) |
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

**Pending, on a physical Android device, with a listener:**

0. Run `./gradlew :inderun-kotlin:connectedAndroidTest` with the phone connected, and record its traces like the
   emulator table above.

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
  -Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true`, then `adb logcat -d -s IndeRunBenchmark:I`.

Each sample is one `INDERUN-BENCH` line, and each step one `INDERUN-BENCH-SUMMARY` line with the median, maximum and
count. Cold and warm calls are never pooled. `firstAudioMs` is the platform's first word callback; `wallMs` is
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

**Pending:** the same runs on a physical iPhone and a physical Android phone, with several trials per step, and with a
second voice per language.

### Running the scenarios on another provider

The scenarios use only the public speech API, so they compare any provider that declares `text_to_speech`. Each
platform's benchmark has a list of targets, a provider and optionally one pinned voice, in `SpeechBenchmarkTests.swift`
and `SpeechBenchmarkTest.kt`. Adding an entry adds a column to the tables above; the scenarios do not change. A scenario
whose delivery a target does not declare is reported as `unsupported` for it, and a target without a voice for the
locale as `unavailable`.

Candidates this is meant for, none of which IndeRun ships today:

- a neural model on ONNX Runtime or Core ML, wrapped as a `text_to_speech` provider;
- a custom voice built as an `AVSpeechSynthesisProviderAudioUnit` extension: the system lists it like any other voice,
  so it is the existing `apple_system_speech` target with that voice pinned;
- a second Android TTS engine, or a cloud speech provider, for comparison.

Each needs the provider admission decision first; the neural candidates are evaluated in #260. Keep the scenarios and
the corpus unchanged when comparing, so the numbers stay comparable.

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

**Pending** for 0.5: install the published packages and run the steps in
[release.md](../release.md#release-smoke-check), then record each platform here with its version.

