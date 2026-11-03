# System Speech Provider Family

System speech adapters put a platform's own text-to-speech behind the canonical provider interface. They are the first
`text_to_speech` providers and the reference for playback semantics. The application API and its reasoning are in
[ADR 018](./decisions/018-speech-application-api.md); task semantics are in
[ADR 016](./decisions/016-modality-extensible-task-contracts.md).

| Platform  | Provider id             | Where                                  | Playback | Artifact    |
| --------- | ----------------------- | -------------------------------------- | -------- | ----------- |
| iOS/macOS | `apple_system_speech`   | `IndeRunAppleProviders`                | Yes      | `audio/wav` |
| Android   | `android_system_speech` | `inderun-system-speech-providers`      | Yes      | `audio/wav` |
| Web       | `web_system_speech`     | `@independo/inderun-web/system-speech` | Yes      | No          |

## What every member does

- **Registered explicitly.** Default registries stay unchanged, because the router probes every registered provider on
  every request.
- **Commits before sound.** A failure after that ends the run rather than speaking the text twice.
- **Streams only its lifecycle.** `stream()` emits no content events. It ends with `result`, or quietly when cancelled.
  `speak()` depends on this for cancellation.
- **One utterance at a time, per provider instance, first in first out.** A later call waits and commits only at its
  turn. Cancelling a waiting call plays nothing. An application that wants to interrupt cancels first.
- **Every voice is listed.** The adapter reports each voice with its platform identifier as an opaque `id`, a `name`
  (Android has no label, so it repeats the id) and its traits, and re-finds the bound one by `id` before use. A voice
  that vanished since planning fails with `CapabilityMismatch` before commit, so fallback stays possible.
- **Prepare makes a voice ready (ADR 019).** Apple warms a voice with a silent render, Android selects it so the engine
  downloads it, and Web waits for the browser's list. Android lists a voice still to be downloaded as `not_prepared`
  instead of hiding it. The engine's own download is the only one: IndeRun fetches and stores nothing.
- **The list order is the default.** The planner breaks ties by listing order, so the platform's own choice comes ahead
  of its equals. On Apple, novelty voices come last. `speech.voice.id` overrides this; see ADR 018.
- **Does not hang on a silent engine.** An utterance that never starts fails within a bound instead of holding the
  provider's turn. An utterance that started and then never reports an ending has no such bound; `speak()` can still stop
  it, and on the Web a `run()` playback cannot be stopped.
- **Never substitutes.** A required locale, voice or format is met or refused, and playback and artifact never stand in
  for each other.
- **Reports when the first word started.** A finished playback carries `playback.firstAudioMs`, from handing the
  utterance to the platform until the platform's first word callback: `willSpeakRangeOfSpeechString` on Apple,
  `onRangeStart` on Android, the first `boundary` event on the Web. It measures the platform and the voice, not
  routing, and not sound at the speaker. An engine or browser that reports no word ranges leaves it out, and a stopped
  run reports none.

## Locality

A system API is not automatically offline. Each member states what it can actually observe:

- **Apple.** `AVSpeechSynthesisVoice` exposes no network flag. The provider lists installed voices and declares
  `dataLeavesDevice: false` on that basis, so the claim is an assumption the API does not prove. The airplane-mode check
  in [the verification record](../verification/system-speech.md) is still pending.
- **Android.** Each voice reports `Voice.isNetworkConnectionRequired`, so `local_required` binds an on-device voice or
  refuses. Voices that are not installed are dropped, and network voices are dropped while offline. An engine that lists
  no voices gives nothing to check, so a `local_required` request is refused before commit with
  `details.code: "voice_locality_unknown"`; other requests let the engine choose for the locale. The flag is the
  installed engine's own statement, and the user chooses that engine, so `local_required` and `on_device` are only as
  good as its report. Only Google TTS has been run.
- **Web.** `SpeechSynthesisVoice.localService` is unreliable and absent in places, so it is only an input. The task
  declares that data may leave the device, `local_required` is always refused, and provenance reports `unknown`. A voice
  with `localService: false` is marked `networkRequired` and dropped while offline; voices that claim to be local are
  listed first, so they win ties.

## Platform limits

- **Apple.** The first utterance with a voice after launch waits for that voice to load, over a second on an iPhone.
  Later ones start in about 160 ms, because playback keeps one synthesizer per provider instance.
  `AVSpeechSynthesisVoice` reports gender, so a required gender can be served. The audio session belongs to the
  application, so under the default category the Silent switch mutes playback and the run still finishes `stop`. A
  session interruption ends a playing utterance as `Unavailable` with `details.code: "speech_interrupted"`,
  because the synthesizer may never resume it. Provider implementation detail lives in code comments in
  [`IndeRunAppleProviders`](../../ios/IndeRun/Sources/IndeRunAppleProviders).
- **Android.** `Voice` exposes no gender, so a required gender ends in `voice_not_available` and a preferred one stays
  unmet. Capabilities differ per installed engine and voice. `synthesizeToFile` promises a file, not a format, so a
  non-WAV result is refused before commit. The engine's queue and voice selection are shared, so playback and synthesis
  take turns; on Apple synthesis runs alongside playback. Detail lives in code comments in
  [`inderun-system-speech-providers`](../../android/inderun-system-speech-providers).
- **Web.** Playback only: no standard API retrieves the audio, so `generateSpeech()` is refused by routing rather than
  answered with empty bytes. `run()` cannot be cancelled here, so use `speak()`. Voices have no gender. Chrome refuses to
  speak without a user gesture; that surfaces as `Unavailable` with `details.code: "speech_not_allowed"`, after commit,
  because the browser only says so once asked. `speechSynthesis` is one queue per page and `cancel()` empties all of it,
  with no way to remove one utterance. So the provider waits, before commit, for speech the application started directly
  to end, and stopping a call that is waiting leaves that speech alone. Speech the application queues while the
  provider's own utterance plays is removed when that utterance is stopped. Detail lives in code comments in
  [`providers/system-speech`](../../packages/inderun-web/src/providers/system-speech).

Quality, latency and device results belong in the [verification record](../verification/system-speech.md), not here.
