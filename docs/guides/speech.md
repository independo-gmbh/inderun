---
slug: docs/guides/speech
title: "Read text aloud: voices and privacy"
description: "Add text-to-speech in the Web, Swift, Kotlin and Capacitor SDKs, check which voices stay on the device, and refuse speech that would leave it."
sidebar:
  order: 1
---

The first question about speech is not how to add it. It is where the voice runs: on the device, or on a server. Platform text-to-speech APIs can do either, and the answer differs by platform and by voice. This page covers what each platform lets IndeRun enforce, and how to ask for on-device speech. For the full platform summary, see [Compatibility and requirements](../platforms/compatibility.md).

<!-- version:tested-set -->
Tested set: IndeRun **0.5.0** (`@independo/inderun-web`, SwiftPM, Maven) and `@independo/capacitor-inderun` **1.3.0-dev.1**, which wraps IndeRun 0.5.0. Examples type-checked against these on 2026-11-11.
<!-- /version -->

## Speak text

On the web, `speak()` starts playback and returns a handle straight away:

<!-- snippet:web-speak -->
```ts
import { createIndeRunWeb, listVoices, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });

const voices = await listVoices(inderun, { locale: "de-DE" });
console.log(voices.map((voice) => voice.name));

const playback = await speak(inderun, { text: "Ihr Termin wurde verschoben.", locale: "de-DE" });
document.querySelector("#stop")?.addEventListener("click", () => playback.cancel());

const { outcome, provenance } = await playback.result;
console.log(outcome, provenance?.locality); // locality: "unknown" in a browser
```
<!-- /snippet -->

The handle has two parts:

- `cancel()` stops playback. It can be called more than once. Wire it to your own stop control.
- `result` is a promise that settles when playback ends. It resolves when playback finishes or is stopped (`outcome` tells you which) and rejects with the run's error if playback failed. `provenance.locality` says where the voice ran; in a browser it is `"unknown"`.

`speak()` needs a `locale` (a BCP 47 tag such as `de-DE`). Browsers, Chrome in particular, may refuse to speak without a user gesture, so start playback from a click or tap.

In the Capacitor plugin, `speak()` is a method of the instance. Speech providers register only when asked for, so pass `systemSpeech: true`:

<!-- snippet:capacitor-speak -->
```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// Speech providers register only when asked for. `systemSpeech` is AVSpeechSynthesizer on iOS and
// TextToSpeech on Android; the app never receives audio bytes.
const ai = createIndeRunCapacitor({ systemSpeech: true });

const playback = await ai.speak({
  text: "Your appointment has been rescheduled.",
  locale: "en-US",
  execution: { privacy: "local_required" }
});

// Stop early with `cancel()`; no audio plays after it returns.
setTimeout(() => void playback.cancel(), 1500);

// `result` settles when playback ends or is stopped.
const result = await playback.result;
console.log(result.outcome, result.provenance?.providerId);
```
<!-- /snippet -->

`cancel()` stops the audio and `result` settles when playback ends or is stopped, as on the web. The app never receives audio bytes.

## Which voices stay on the device

| Platform | How IndeRun decides | What that means |
| --- | --- | --- |
| Android | Each voice's own network flag (`Voice.isNetworkConnectionRequired`) | Enforced: `local_required` uses a voice that reports it needs no network, or the request is refused. The flag is the installed speech engine's own statement. |
| iOS and macOS | Installed Apple voices are assumed local | Assumed, not proven: the API exposes no network flag. The airplane-mode check is still pending. |
| Web | Not provable | Browsers can't confirm locality, so `local_required` speech is always refused. Provenance reports `unknown`. |

None of this is an offline guarantee. A voice reported as local is a statement by the platform or the speech engine, and IndeRun passes it on rather than measuring it. The detail, including how voices are filtered and what each platform's limits are, is in the [system speech provider family](../architecture/system-speech-provider-family.md).

A neural speech provider family also exists in the SDKs: see [neural speech provider family](../architecture/neural-speech-provider-family.md).

## Require on-device speech

Set `execution.privacy` to `"local_required"`. IndeRun then keeps only voices that stay on the device, and refuses the request if none remains. As with text, a refusal means no provider ran; see [When on-device AI is unavailable](../concepts/routing-and-privacy.md).

- **Android.** Enforced through the voice's network flag. If the installed engine lists no voices at all, there is nothing to check, so a `local_required` request is refused before it starts with `details.code: "voice_locality_unknown"`. Requests without `local_required` let the engine choose a voice for the locale.
- **iOS and macOS.** Installed voices are assumed local, so `local_required` can succeed. That is an assumption of the provider, not a proof.
- **Web.** Always refused:

<!-- snippet:web-speak-local-required -->
```ts
import { createIndeRunWeb, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });

try {
  await speak(inderun, {
    text: "Ihr Termin wurde verschoben.",
    locale: "de-DE",
    execution: { privacy: "local_required" }
  });
} catch (error) {
  // Always refused in a browser: it cannot prove that a voice stays on the device.
  console.warn(error);
}
```
<!-- /snippet -->

`local_required` never opens a cloud route. If you want speech that may use a network voice, leave `local_required` off and expect `provenance.locality` to tell you what happened.

## Get audio instead of playback

`generateSpeech()` returns audio as a media artifact instead of playing it. It returns WAV on iOS and Android. On the web it is refused: no standard browser API returns the audio, so IndeRun refuses the request instead of returning empty bytes. Use `speak()` for playback in a browser.

With the Web, Swift and Kotlin SDKs, read the returned artifact with `readArtifact()` and release it with `disposeArtifact()`; see the [Web SDK README](../../packages/inderun-web/README.md). The Capacitor plugin works the same way:

<!-- snippet:capacitor-generate-speech -->
```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor({ systemSpeech: true });

// Silent: this returns an artifact handle, never bytes. The audio is WAV on iOS and Android; the
// browser's system speech can only play, so routing refuses it here.
const speech = await ai.generateSpeech({
  text: "Your appointment has been rescheduled.",
  locale: "en-US",
  mediaTypes: ["audio/wav"]
});

try {
  const chunks: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    const chunk = await ai.readArtifact({ artifactId: speech.artifact.id, offset });
    chunks.push(chunk.bytes);
    offset += chunk.bytes.byteLength;
    if (chunk.done) {
      break;
    }
  }
  const wav = new Blob(chunks as BlobPart[], { type: speech.artifact.mediaType });
  console.log(wav.size, speech.artifact.mediaType);
} finally {
  await ai.disposeArtifact(speech.artifact);
}
```
<!-- /snippet -->

## Choose a voice

`listVoices()` returns the voices the registered providers offer right now. Pass `locale` to keep only voices that can serve a language:

```ts
const voices = await listVoices(inderun, { locale: "de-DE" });
```

Each entry carries a `locale`, an opaque `id` that is meaningful only on that device, a display `name` and, where the provider can tell, `networkRequired`. Pass an entry as `voice` to `speak()`. Never write an `id` by hand.

A missing voice fails rather than being replaced. If you require a voice that is no longer installed, the request is refused with `voice_not_available`; if you only prefer it (the default), the traits stored with the voice choose instead (see [ADR 018](../architecture/decisions/018-speech-application-api.md)). The `speech` field of the result reports the locale and voice actually used, so an unmet preference is visible. By default the locale matches by language, so `de-AT` may be served by a `de-DE` voice; ask for `localeMatch: "exact"` if you need the whole tag. A locale with no voice is refused with `locale_not_supported`.
