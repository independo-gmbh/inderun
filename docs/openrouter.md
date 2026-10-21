# OpenRouter

[OpenRouter](https://openrouter.ai) is a hosted gateway to many model vendors behind one API key. It exposes a
Responses API endpoint, so IndeRun reaches it through the existing OpenAI-compatible provider on every platform —
there is no separate OpenRouter provider, and no OpenRouter-specific type in the public API.

OpenRouter is one **cloud target** among the ones an app registers. It does not replace IndeRun's routing: privacy
constraints, model profiles, capability checks, fallback and provenance work exactly as for any other cloud target.
OpenRouter's own provider routing happens *inside* that one target, after IndeRun has already chosen it.

> **How this was verified.** The behavior below is verified against OpenRouter's published documentation
> ([Responses API](https://openrouter.ai/docs/api/reference/responses/overview),
> [Errors and debugging](https://openrouter.ai/docs/api/reference/errors-and-debugging)) and the shared fixtures that
> encode it, not against a live OpenRouter account. See [What is not verified](#what-is-not-verified).

## Configuration

| Setting | Value |
| --- | --- |
| Endpoint | `https://openrouter.ai/api/v1/responses` |
| Credentials | An OpenRouter API key, sent as `Authorization: Bearer …`, resolved from secure storage through `authContextRef`. Never put the key in a request payload. |
| Models | OpenRouter model ids, `vendor/model` — for example `openai/gpt-5.2` or `anthropic/claude-sonnet-4.5`. |
| Target ids | The factories register one target per model as `<id>:<model>`. With `id: "openrouter"` that gives `openrouter:openai/gpt-5.2`. |

Web, behind a same-origin proxy that holds the OpenRouter key server-side (the recommended browser setup):

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  openAI: {
    id: "openrouter",
    models: ["openai/gpt-5.2", "anthropic/claude-sonnet-4.5"],
    endpointUrl: "/api/inderun/openrouter-responses",
    auth: "none"
  },
  modelProfiles: {
    smart: ["openrouter:anthropic/claude-sonnet-4.5", "openrouter:openai/gpt-5.2"]
  }
});
```

`createIndeRunWeb` refuses `https://openrouter.ai/api/v1/responses` with browser-held credentials unless
`allowDirectOpenAIEndpoint: true` is set, for the same reason it refuses OpenAI's endpoint: the key would ship in
client code. `createIndeRunWeb` takes one `openAI` configuration; to use OpenAI and OpenRouter side by side, register a
second `OpenAIResponsesProvider` from `@independo/inderun-web/openai` on your own `ProviderRegistry`.

Swift and Kotlin use the same factory with the OpenRouter endpoint; the key stays in the platform keychain or keystore
slot that `authContextRef` names:

```swift
let registry = try AppleCloudProviderRegistryFactory.makeOpenAIRegistry(options: OpenAIFactoryOptions(
    id: "openrouter",
    models: ["openai/gpt-5.2"],
    endpointURL: "https://openrouter.ai/api/v1/responses",
    authContextRef: "openrouter"
))
```

```kotlin
val registry = AndroidCloudProviderRegistryFactory.makeOpenAIRegistry(
    OpenAIFactoryOptions(
        id = "openrouter",
        models = listOf("openai/gpt-5.2"),
        endpointUrl = "https://openrouter.ai/api/v1/responses",
        authContextRef = "openrouter",
    ),
)
```

To try it from the web demo, point the demo proxy at OpenRouter: set `INDERUN_OPENAI_ENDPOINT_URL` to the endpoint
above, `OPENAI_API_KEY` to the OpenRouter key, and `INDERUN_OPENAI_MODEL` to a `vendor/model` id (see
[`@independo/inderun-demo-proxy`](../packages/inderun-demo-proxy/README.md)).

## Behavior

**Stateless.** OpenRouter's Responses endpoint keeps no conversation state and rejects `store: true` and
`previous_response_id`. IndeRun sends neither: every request carries its full `messages` history.

**Streaming (Mode 2).** OpenRouter streams the Responses event vocabulary. The provider also accepts what OpenRouter
adds to it: SSE comment lines it sends as keep-alives (`: OPENROUTER PROCESSING`), a `response.error` event, and a
mid-stream failure sent as an untyped event with a top-level `error` object. Every one of these ends the run with a
normalized error; none is mistaken for a truncated stream.

**Errors.** OpenRouter reports its error `code` as the HTTP status number. The provider classifies a numeric code exactly
as it classifies that HTTP status, whether it arrives as the response status, in a `200` body, or in a stream event:

| Status / code | IndeRun error | Retryable |
| --- | --- | --- |
| `401`, `403` | `AuthError` | no |
| `402` (insufficient credits) | `Unavailable` | no — the account needs credits |
| `402` with `Retry-After` (in-flight budget limit) | `RateLimited`, with `retryAfterMs` | yes |
| `408`, `504` | `Timeout` | yes |
| `429` | `RateLimited`, with `retryAfterMs` when `Retry-After` is sent | yes |
| `409`, `5xx` | `Unavailable`, with `retryAfterMs` when `Retry-After` is sent | yes |
| other `4xx` | `Internal` | no |

A failed Responses run carries a typed `error_type` beside `error` — on the response object for `200` bodies and
`response.failed` events, in `error.metadata` for untyped error events — because the native `error.code` collapses
many causes into `server_error`. When `error_type` is present and known, it decides the class: the provider classifies
it by the HTTP status OpenRouter documents for that type, so `authentication` is an `AuthError`, `payment_required`
behaves like `402`, and `timeout` like `504`. `refusal` and `content_policy_violation` are documented as `403` but are
not credential failures, so they classify as a rejected request (`Internal`). An unknown `error_type` leaves the code in
charge; the native `invalid_prompt` code is `Internal` as well.

A `200` response whose body is a failure — `status: "failed"`, or an `error` object and no output — fails with the
mapped error instead of an empty answer. In Mode 1, IndeRun falls back to the next target whatever the error class, so a
`402` moves on to the next target of the profile just as a `503` does.

**Reported model.** When OpenRouter names the model that served the request, it becomes the provenance
`reportedModel`; the configured `vendor/model` id is the `configuredModel`. IndeRun never infers which upstream vendor
OpenRouter chose beyond what the response says.

**Cancellation.** Cancelling a stream closes the connection immediately, as for any OpenAI-compatible target, and
IndeRun's cancellation guarantees hold. Whether the *upstream* model stops generating — and stops billing — depends on
the vendor OpenRouter routed to; OpenRouter documents that only some upstream providers support it.

**Attribution headers.** OpenRouter's optional app-attribution headers (`HTTP-Referer`, `X-OpenRouter-Title`) are not
configurable yet; the provider sends no custom headers. A proxy can add them server-side.

## What is not verified

These depend on live behavior the published documentation does not pin down, and are open on
[#186](https://github.com/independo-gmbh/inderun/issues/186) until someone runs the Mode 1 and Mode 2 checks against a
real account:

- the exact SSE event names OpenRouter's Responses stream emits for failures (all three documented shapes are handled);
- whether the `model` field on `/responses` echoes the routed vendor model or the requested id;
- the HTTP status of a run that fails after OpenRouter has accepted it (the provider handles both a status and a
  `200` body);
- the `402` in-flight budget body and headers on `/responses`, which the errors page documents for the API in general.
