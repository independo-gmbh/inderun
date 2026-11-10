---
slug: docs/concepts/routing-and-privacy
title: "When on-device AI is unavailable"
description: "What happens when Apple Foundation Models, Gemini Nano or the browser model is unavailable: local_required, local_preferred and opt-in cloud routes."
sidebar:
  order: 1
---

On-device models are not on every device. IndeRun lets each request say where it may run, and tells you plainly when it can't run there. This page explains why a model can be unavailable, the four rules you choose from and how IndeRun applies them. For the parts of the SDK involved, see [How IndeRun is structured](architecture.md).

## Why on-device models are sometimes unavailable

The platforms own these models, and each decides which devices get one. People use older phones, switch features off and have storage or battery limits, so an app can run fine and still have no eligible model. Check [Compatibility and requirements](../platforms/compatibility.md) for the tested set.

### iOS

Apple Foundation Models needs a device that supports Apple Intelligence, with Apple Intelligence turned on, and the model downloaded and ready. The framework reports why it is unavailable (for example an ineligible device, Apple Intelligence off or a model that is not ready). See [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) and [Apple Intelligence](https://developer.apple.com/apple-intelligence/).

### Android

ML Kit GenAI uses Gemini Nano through the system's AICore. Which devices and model versions are supported differs by device and may change, and the shared model may still need to be downloaded. See [ML Kit GenAI](https://developers.google.com/ml-kit/genai).

### Web

The web system-model provider uses the browser's built-in model. Chrome documents the Prompt API for desktop Chrome, with hardware and storage requirements and a first-use model download; other browsers don't implement it yet. See [Chrome Prompt API](https://developer.chrome.com/docs/ai/prompt-api). Requirements change with Chrome releases, so check that page rather than this one.

## Choose a rule per request

Placement is a property of the request. Set `constraints.privacy`:

| `constraints.privacy` | What IndeRun does |
| --- | --- |
| `local_required` | Removes every provider whose data leaves the device. If none remains, the request is refused. A cloud route is never used, even if one is configured. |
| `local_preferred` | Removes nothing. On-device providers are ranked first; a cloud target that you configured separately and that the request permits stays eligible. |
| `cloud_allowed` (default) | No preference from privacy. Default ranking still prefers local over cloud. |
| `cloud_required` | Removes every provider that is not a cloud target. |

`constraints.cloud` (`forbidden`, `allowed`, `required`) is a separate setting. It outranks `constraints.privacy` when ordering providers; for removal, the two apply independently.

## How IndeRun chooses where to run

![Flowchart of how IndeRun routes a request: the app sends a task with constraints, IndeRun reads capabilities and host conditions, filters, and asks whether any provider is eligible. If none, it refuses and nothing runs (outcome B). Otherwise it ranks, chooses a permitted route and executes, ending on the device (outcome A) or on an allowed cloud target (outcome C).](../assets/diagrams/routing-flow.svg)

**Text equivalent of the diagram:**

1. The app sends a task and its execution constraints.
2. IndeRun reads the registered providers' capabilities and the host conditions.
3. IndeRun filters by task, interaction mode, availability and hard policy constraints.
4. Decision: is any provider eligible?
   - **No:** the request is refused with a normalized reason. Nothing runs (outcome B).
   - **Yes:** continue.
5. IndeRun ranks the eligible providers and chooses a permitted route.
6. IndeRun executes through the selected provider and returns a normalized result with provenance. The outcome is either **A**, the task ran on the device, or **C**, it ran on a cloud target you configured and the request allowed.

Outcome C exists only when you registered a cloud target. Host services inform availability, but they are not a step in the request. The diagram illustrates selection logic; it is not a trace of every engine method. The implementation detail is in [Placement constraints](../architecture/architecture.md#placement-constraints).

## Refusal, cloud route and fallback are different things

- **Refusal.** No provider survived the filter. `run()` rejects with an `IndeRunError` whose `errorClass` is `"CapabilityMismatch"` and whose `details.rejectedProviders` names each provider and its reason codes (for example `privacy_constraint` or `capability_unavailable`). Nothing executed. This is correct behaviour under your rule. See [Read the outcome](../getting-started/capacitor.md#read-the-outcome).
- **Cloud route.** With `cloud_allowed`, or with `local_preferred` when no local provider is eligible, and a configured, permitted cloud target, IndeRun may select the cloud target as its first choice. That is a route decision, not a fallback: `provenance.fallbackOccurred` stays `false`.
- **Fallback.** `provenance.fallbackOccurred` is `true` only when IndeRun actually attempted more than one provider. `local_required` removes cloud targets from the chain, so a fallback can never reach one.

`provenance.locality` reports `"on_device"`, `"edge"`, `"cloud"` or `"unknown"`. It is the selected provider's declaration, not a measurement. No edge provider ships today.

## Optional: add a cloud route safely

Skip this section if on-device only is what you want. To allow a cloud route, register an OpenAI-compatible target that points at **your server**, not at a vendor with a key in the app. The proxy adds the API key server-side, so the app uses `auth: "none"`. Never ship an API key in an app bundle or a request payload.

<!-- snippet:capacitor-cloud-route -->
```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// Credentials stay on your server; the app calls your proxy.
const ai = createIndeRunCapacitor({
  openAI: {
    models: ["your-model-id"],
    endpointUrl: "https://api.example.com/inderun/v1", // your OpenAI-compatible proxy
    auth: "none" // the proxy adds the API key server-side
  }
});

const result = await ai.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
  // Tries the device first; the configured cloud target stays eligible.
  constraints: { privacy: "local_preferred" }
});

console.log(result.provenance?.locality, result.provenance?.fallbackOccurred);
```
<!-- /snippet -->

Google calls this pattern hybrid inference ([Firebase AI Logic](https://firebase.google.com/docs/ai-logic/hybrid-on-device-inference)). With `local_preferred` the device is tried first and the cloud target stays eligible; with `local_required` it is never used. Cloud providers have their own data-processing policies, which you need to review. For a hosted gateway example, see the optional [OpenRouter guide](../../docs/openrouter.md).

## What IndeRun does and doesn't promise

- It applies your rule before anything runs, and reports what happened in `provenance`.
- It does not promise that an on-device model exists, or that your app works offline. Availability depends on the device, OS, browser and released version.
- It makes no compliance claim. `local_required` is a routing rule, not a GDPR or other certification, and it does not control what the rest of your app sends over the network.
- Telemetry is a local hook in your app. The default handler discards events, and IndeRun sends nothing to Independo.
