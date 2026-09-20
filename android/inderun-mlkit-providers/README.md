# IndeRun ML Kit Providers (Android)

Android provider adapters backed by ML Kit GenAI APIs.

This module provides the on-device `AndroidMlKitGenAiProvider` for `text_to_text` requests in both
Mode 1 (`run()`) and Mode 2 (`stream()`), backed by the ML Kit GenAI Prompt API (Gemini Nano).

## Streaming

The provider declares `streamingStyle: chunks` and `cancel: soft`. ML Kit hands back incremental
text, so each chunk becomes a `content_delta` event that appends to the run's partial text — it is
never a cumulative snapshot. The runtime reports no token usage, so the terminal outcome carries none.

Completion maps from ML Kit's own finish reason:

| ML Kit `Candidate.FinishReason` | IndeRun `finishReason` |
| --- | --- |
| `STOP` ("natural stop point of the model") | `stop` |
| `MAX_TOKENS` | `length` |
| `OTHER` ("all other reasons that stopped the generation") | `error` |
| absent | `stop` (defensive — ML Kit documents the reason as non-null on the final response) |

`error` here is the contract's "provider reported a non-fatal issue on an otherwise completed run",
not a failed run; a failed run throws or takes the terminal `error` outcome instead.

## Policy rejections

Gemini Nano can refuse a prompt (`REQUEST_PROCESSING_ERROR`) or a response it has already started
generating (`RESPONSE_GENERATION_ERROR`, `RESPONSE_PROCESSING_ERROR`). ML Kit documents the two
response-side codes as able to interrupt streaming with an incomplete result, and advises removing
that result from the app's UI.

The adapter therefore emits an **empty `content_snapshot`** before failing, which resets the run's
cumulative text — a snapshot replaces rather than appends — so the terminal `error` carries no
rejected content and a consumer rendering content events clears with it. All three of these codes
classify as `CapabilityMismatch` rather than `Internal`: the taxonomy has no content-policy class,
and `Internal` means an unexpected engine-side failure. `details.mlKitErrorCode` still separates the
causes.

Cancellation is `soft` because ML Kit does not document that AICore stops generating when the
caller walks away. The adapter stops relaying and the engine's Event Gate is what guarantees the
caller sees exactly one terminal outcome and nothing after it.

## Availability

`GenerativeModel.checkStatus()` is mapped to a four-state `AndroidMlKitGenAiAvailability`
(`Available` / `Downloadable` / `Downloading` / `Unavailable`) and re-checked immediately before
every attempt in both modes, so a stale route decision surfaces as `CapabilityMismatch` rather than
as a native ML Kit failure. One gate covers both modes, so the provider never reports a separate
`streamingAvailable`: a model that is downloadable or downloading is provider-unavailable, with its
own reason, not stream-unavailable.

The provider does not initiate the model download itself (`download()` and `warmup()` are not
called), so a `DOWNLOADABLE` model stays unroutable until the host app fetches it.

## Device requirements

- Android 8.0+ (API 26)
- A device with on-device generative-AI support (AICore / Gemini Nano); most emulator images report
  `Unavailable`, which is expected
- Not supported on devices with an unlocked bootloader

## Runtime seam

Everything that touches `com.google.mlkit` sits behind `AndroidMlKitGenAiRuntime`
(`availability()`, `generateText()`, `generateTextStream()`). The production implementation wraps
`Generation.getClient()`; tests inject their own, which is why the adapter's descriptor, capability
gate, event shape, error taxonomy and cancellation behavior are all verifiable on a plain JVM
without an AICore device. Only the on-device smoke test documented in
[`../inderun-demo-app/README.md`](../inderun-demo-app/README.md) covers ML Kit's real behavior.
