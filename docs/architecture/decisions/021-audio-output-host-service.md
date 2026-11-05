# ADR 021 — Audio output host service

## Status

Accepted. Recorded for Milestone 5 (issue #260). It gives the PCM that a provider synthesizes itself a place to play,
which [ADR 017](./017-media-artifacts.md) sections 6 and 7 leave to the playback path, and it supplies the audio sink
that the timing origin in [ADR 020](./020-neural-speech-and-model-packages.md) section 3 measures against.

## Context

The neural speech provider planned for the next PR synthesizes PCM and has to play it. The three system speech
providers never needed this, because the platform synthesizer plays what it speaks.

[ADR 017](./017-media-artifacts.md) section 6 says playback is not an artifact, and section 7 keeps media bytes out of
events. The audio therefore cannot leave through either; it leaves through the playback path, and the code that plays
it is platform access. Platform access belongs in host services, not in providers, so a provider stays free of
`AVAudioEngine`, `AudioTrack` and Web Audio.

Providers also need one definition of "nothing audible after cancel" and one of time to first audio. Without them a
benchmark cannot compare model families, and the cancellation guarantee would depend on how each provider happened to
be written.

## Decision

### 1. The service and its guarantees

`HostServices.audioOutput` is an optional `AudioOutputService`, optional like `streamingHttpClient`. It opens
`AudioOutputSession`s, and each session has four operations:

- `open(format)` validates the format and makes no sound. A failed open throws before the provider commits.
- `write(samples)` resolves once the samples are buffered, which is the backpressure, and is the first audible effect.
- `drain()` resolves when everything written has played.
- `stop()` is immediate. It discards buffered audio, releases the output, and is idempotent. Nothing renders after it.

Sessions of one service are independent. The format rule is shared by every host: mono, `pcm_s16le`, 8000 to 48000 Hz.
Cancellation is `stop()` on every platform. The TypeScript `open()` also takes an abort `signal`, which rejects the open
with an `AbortError`; on Swift and Kotlin an open is cancelled by `Task` or coroutine cancellation. After `open()`
returns, the provider's cancel path calls `stop()`.

`contracts/fixtures/host/audio-output-lifecycle.json` is the executable form. Its nine cases run against a fixture
service in every SDK, against the real engine on Swift (skipping where the machine renders no audio), and instrumented
on the Android emulator.

### 2. A host without the service

A provider that needs audio output refuses a playback request before commit with `CapabilityMismatch` and
`details.code: "audio_output_unavailable"`, the convention of [ADR 016](./016-modality-extensible-task-contracts.md)
section 4. Routing then falls through to the profile's next target, normally a system speech provider. The neural speech
provider implements this refusal in the next PR; this ADR states the rule.

Reporting availability per delivery on `ProviderTaskAvailability`, so the planner could reject such a provider earlier,
is a flagged follow-up and is not built.

### 3. The timing origin

`firstAudioMs()` counts from the start of `open()`, the instant it was called. It is the host's observation of the first
frame leaving the output; the web service can only report the time `open()` spent plus the scheduled start and the
output latency the browser states. The provider converts it to the request-received origin that ADR 020 section 3
defines before it reports `PlaybackTiming.firstAudioMs`. The value is `undefined` until a frame has been observed.

### 4. Audio session and focus stay app-owned

The default services set no `AVAudioSession` category and request no Android audio focus. The application that owns the
audio session keeps owning it. Android plays with `USAGE_ASSISTANCE_ACCESSIBILITY` and `CONTENT_TYPE_SPEECH`.

When the system takes the output away, such as an engine configuration change or an interruption, the session ends with
`audio_output_interrupted`, as `speech_interrupted` does for system speech. The ending is kept: every later `write()` and
`drain()` throws it, so a provider still synthesizing cannot report a cut-off utterance as completed. After the app's
own `stop()` they return instead.

### 5. Error codes

All codes are `details.code` values on the normalized error:

| Code                       | Class                | Raised by                                                         |
| -------------------------- | -------------------- | ----------------------------------------------------------------- |
| `audio_format_unsupported` | `CapabilityMismatch` | `open()`, for a format the shared rule does not allow             |
| `audio_not_allowed`        | `Unavailable`        | `open()` on the web, when the browser keeps the context suspended |
| `audio_output_failed`      | `Unavailable`        | the output failing to start or render                             |
| `audio_output_interrupted` | `Unavailable`        | the system ending a session                                       |
| `audio_output_unavailable` | `CapabilityMismatch` | a provider, when the host has no service                          |

## Consequences

- Every PCM-producing provider shares one playback seam, and one definition of cancel and of first audio.
- A host can replace the service. The lifecycle fixture doubles as the test double, so a provider test needs no audio
  device.
- A host without the service is a supported configuration. It still routes to system speech.
- An application that already owns an audio session keeps it. Ducking and interruption policy are not the SDK's, and a
  session that the system interrupts ends rather than resuming.
- The web default needs a user gesture before the first `open()`. `audio_not_allowed` is how a page learns that.
- The catalog proves the lifecycle, not what a listener hears. That stays a manual check.
- The service plays PCM only. Other encodings, mixing, and sessions that outlive a request are out of scope.
