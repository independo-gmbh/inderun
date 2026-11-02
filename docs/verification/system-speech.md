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

**Pending, on a physical iPhone, with a listener:**

1. Run `ios/SampleApps/IndeRunDemo`. Speak `de-AT` and `de-DE` text; note which voice and region spoke.
2. Pick a language with no installed voice; confirm a refusal and no sound.
3. Speak short and long text; press **Stop** mid-utterance; note the stop latency.
4. Turn on airplane mode, speak with the app's default `local_required` policy, and confirm it still speaks.
5. Speak while a call or timer interrupts; confirm the outcome is `failed` with `speech_interrupted` and nothing resumes.
6. Background the app during speech and return; record what happens.
7. Turn on VoiceOver and speak; record how the two overlap.
