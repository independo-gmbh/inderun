/**
 * Application entry point for the IndeRun Web SDK (`@independo/inderun-web`).
 *
 * It leads with the primary text API (`generateText` / `streamText`) and the
 * factory that builds a ready engine, then carries the advanced task API
 * (`run()` / `stream()` / `checkCapabilities()`) and the contract, error and
 * telemetry types those signatures use. See `docs/architecture/api-layering.md`.
 *
 * Two kinds of export live elsewhere on purpose:
 * - provider-authoring and host-integration APIs ship from
 *   `@independo/inderun-web/provider`;
 * - provider adapters ship from their own subpaths (`/openai`, `/onnx`,
 *   `/system-model`), so this surface stays provider-agnostic.
 *
 * The engine's internals (router, route planner bindings, Event Gate) are not
 * exported at all.
 */

/**
 * The primary text API: one canonical request per call, over any `IndeRunApi`.
 */
export {
  generateText,
  streamText,
  toTaskRequest,
  TextStreamRetractedError,
  type GeneratedText,
  type StreamedText,
  type TextExecutionOptions,
  type TextGenerationOptions,
  type TextStream
} from "./facade/text.js";

/**
 * The recommended way in: builds host services, registers the providers named in
 * the options, and returns a ready engine.
 */
export {
  createIndeRunWeb,
  type CreateIndeRunWebOptions,
  type OpenAIFactoryOptions
} from "./web-sdk.js";

/**
 * Model profiles: application-defined names for ordered sets of targets that a
 * request can route within. `"auto"` is built in.
 */
export { AUTO_MODEL_PROFILE, type ModelProfiles } from "./core/model-profiles.js";

/**
 * The advanced task API. `IndeRun` implements `IndeRunApi`; constructing one by
 * hand takes a `ProviderRegistry` and `HostServices` from
 * `@independo/inderun-web/provider`.
 */
export { IndeRun, type IndeRunOptions, type StreamHandleResult } from "./core/engine.js";
export type { IndeRunApi } from "./core/generated/inderun-api.js";
export type { ProviderCapabilitySnapshot, StreamRun } from "./core/provider.js";

/**
 * The contract types this SDK's own signatures take and return.
 *
 * Re-exported so a typed app needs only the one dependency the README tells it to
 * install. `@independo/inderun-contracts` is ours transitively, and under pnpm's
 * isolated `node_modules` an undeclared import of it does not resolve at all.
 * This is the npm counterpart of Gradle `api(...)` on Android and `@_exported
 * import` on Swift — see
 * {@link https://github.com/independo-gmbh/inderun/issues/189 | #189}. The
 * telemetry block below and the host-service block of the `/provider` entry
 * point re-export their halves of the same contract surface for the same reason.
 *
 * Depend on `@independo/inderun-contracts` directly only for what is not
 * re-exported here: the JSON Schemas and the `get*ValidationIssues` validators.
 */
export type {
  ExecutionProvenance,
  IndeRunError,
  IndeRunErrorClass,
  StreamEvent,
  StreamRunHandle,
  StreamTerminalOutcome,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";

/**
 * The normalized error taxonomy. Every failure the SDK surfaces is an
 * `IndeRunException` in one of these classes, whatever the provider raised.
 * Provider authors create them with the `create*` helpers from `/provider`.
 */
export { IndeRunException, toIndeRunException } from "./core/errors.js";

/**
 * Telemetry. Pass a `TelemetryService` to observe routing decisions and attempt
 * outcomes; the engine defaults to `NoOpTelemetryService`.
 */
export {
  type TelemetryEventType,
  type TelemetryEvent,
  type TelemetryService,
  NoOpTelemetryService
} from "./core/telemetry.js";
