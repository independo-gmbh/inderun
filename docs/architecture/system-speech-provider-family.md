# System Speech Provider Family

System speech adapters put a platform's own text-to-speech behind the canonical provider interface. They are the first
`text_to_speech` providers and the reference for playback semantics. The application API and its reasoning are in
[ADR 018](./decisions/018-speech-application-api.md); task semantics are in
[ADR 016](./decisions/016-modality-extensible-task-contracts.md).

| Platform | Provider id | Where | Playback | Artifact |
| --- | --- | --- | --- | --- |
| iOS/macOS | `apple_system_speech` | `IndeRunAppleProviders` | Yes | `audio/wav` |
| Android | `android_system_speech` | `inderun-system-speech-providers` | Yes | `audio/wav` |

## What every member does

- **Registered explicitly.** Default registries stay unchanged, because the router probes every registered provider on
  every request.
- **Commits before sound.** A failure after that ends the run rather than speaking the text twice.
- **Streams only its lifecycle.** `stream()` emits no content events. It ends with `result`, or quietly when cancelled.
  `speak()` depends on this for cancellation.
- **One utterance at a time, per provider instance, first in first out.** A later call waits and commits only at its
  turn. Cancelling a waiting call plays nothing. An application that wants to interrupt cancels first.
- **Voices are traits.** The adapter lists installed voices without identifiers and re-finds the bound one before use. A
  voice that vanished since planning fails with `CapabilityMismatch` before commit, so fallback stays possible.
- **Never substitutes.** A required locale, voice or format is met or refused, and playback and artifact never stand in
  for each other.

## Locality

A system API is not automatically offline. Each member states what it can actually observe:

- **Apple.** `AVSpeechSynthesisVoice` exposes no network flag. The provider lists installed voices and declares
  `dataLeavesDevice: false` on that basis. [The verification record](../verification/system-speech.md) holds the
  airplane-mode evidence for the claim.
- **Android.** Each voice reports `Voice.isNetworkConnectionRequired`, so `local_required` binds an on-device voice or
  refuses. Voices that are not installed are dropped, and network voices are dropped while offline. An engine that lists
  no voices gives nothing to check, so a `local_required` request is refused before commit with
  `details.code: "voice_locality_unknown"`; other requests let the engine choose for the locale.

## Platform limits

- **Apple.** `AVSpeechSynthesisVoice` reports gender, so a required gender can be served. The audio session belongs to the
  application, so under the default category the Silent switch mutes playback and the run still finishes `stop`. A
  session interruption ends a playing utterance as `Unavailable` with `details.code: "speech_interrupted"`,
  because the synthesizer may never resume it. Provider implementation detail lives in code comments in
  [`IndeRunAppleProviders`](../../ios/IndeRun/Sources/IndeRunAppleProviders).
- **Android.** `Voice` exposes no gender, so a required gender ends in `voice_not_available` and a preferred one stays
  unmet. Capabilities differ per installed engine and voice. `synthesizeToFile` promises a file, not a format, so a
  non-WAV result is refused before commit. The engine's queue and voice selection are shared, so playback and synthesis
  take turns; on Apple synthesis runs alongside playback. Detail lives in code comments in
  [`inderun-system-speech-providers`](../../android/inderun-system-speech-providers).

Quality, latency and device results belong in the [verification record](../verification/system-speech.md), not here.
