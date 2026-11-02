# IndeRun System Speech Providers (Android)

`AndroidSystemSpeechProvider` puts `android.speech.tts.TextToSpeech` behind the canonical provider
interface for `text_to_speech`: managed playback and retrievable `audio/wav`, in Mode 1 and Mode 2,
with `hard` cancellation.

```kotlin
val registry = ProviderRegistry()
registry.register(AndroidSystemSpeechProvider(context))
val indeRun = IndeRun(registry, HostServicesFactory.create(context))

val playback = indeRun.speak(SpeakOptions("Der Bus kommt.", locale = "de-AT"), lifecycleScope)
```

The provider is registered explicitly and `IndeRun.initialize` leaves it out, because the router
probes every registered provider on every request and this one binds a system service. Call
`close()` when you are done with it. The module's manifest adds the `TTS_SERVICE` `<queries>` entry
that Android 11 and later require, so an app needs no entry of its own.

Locale, voice, privacy and platform limits are described in
[the family doc](../../docs/architecture/system-speech-provider-family.md).

## Voices still to download

The provider lists a voice the engine has not installed as `not_prepared`, and it never speaks until the engine has it.
Selecting it through `prepare` makes the engine download it. That happens only under `autoDownload` at registration,
`ProviderRegistrationOptions(autoDownload = true)`, or `PrepareRequest(allowDownload = true)`. See ADR 019.
