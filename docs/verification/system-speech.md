# System speech verification record

Results for the system speech providers. Only real runs go here. A check that has not been run says **pending** and
gives the steps; it never carries an assumed result. Automated coverage is listed in
[providers.md](../architecture/providers.md#demos--tests-per-family).

Simulators, emulators and scripted browsers prove routing, callbacks and cancellation. They do not prove what a person
hears, so listening checks need a real device.

## Apple (`apple_system_speech`)

Recorded 2026-11-02 with `AppleSystemSpeechArtifactTests` against the real `AVSpeechSynthesizer`:

| Environment | Check | Result |
| --- | --- | --- |
| macOS host (`swift test`) | `en-US` utterance finishes; a long one ends `cancelled` on `cancel()` | Passed |
| macOS host (`swift test`) | `generateSpeech` returns a WAV artifact that reads back with the right header, size and duration | Passed |
| iPhone 17 Simulator (`xcodebuild test`) | Same two checks | Passed |

The tests observe callbacks and bytes. Nobody listened to the output, and the simulator says nothing about a real audio
route.

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

Recorded 2026-11-02 on the same emulator, for ADR 019. `listVoices` for `de-DE` returned 9 voices, all `not_prepared`,
which the provider used to hide. Picking `de-de-x-nfh-local` ran `prepare` with `allowDownload`. A speak about 2 s later
finished `stop` with that voice and `on_device`, and within 16 s the voice no longer read `not_prepared`. The emulator has
no audio output, so this proves completion, not sound.

**Pending, on a physical Android device, with a listener:**

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
