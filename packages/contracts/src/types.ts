import type {
  IndeRunError,
  MediaArtifact,
  ModelPackage,
  ProviderDescriptor,
  RoutePlan,
  RoutePlannerInput,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "./generated/index.js";
import type { PlaybackOutput } from "./generated/task-output.js";
import type { OutputDeliveryRequest, SpeechInput } from "./generated/task-request.js";

// Convenience aliases derived from the generated schema types, so consumers can
// name individual fields without reaching into the generated index signatures.

/** Contract schema version (e.g. `"1.0"`) carried by every task request. */
export type SchemaVersion = TaskRequest["schemaVersion"];
/** Supported task kinds (`"text_to_text"`, `"text_to_speech"`). */
export type TaskKind = TaskRequest["task"]["kind"];
/** Normalized reason a task finished (e.g. `stop`, `length`, `error`). */
export type FinishReason = TaskResult["finishReason"];
/** The shared error taxonomy value carried on `IndeRunError`. */
export type IndeRunErrorClass = IndeRunError["errorClass"];
/** Input schema consumed by the shared (Rust/WASM) route planner. */
export type SharedRoutePlannerInput = RoutePlannerInput;
/** Route plan produced by the shared route planner. */
export type SharedRoutePlan = RoutePlan;
/** Routing constraints (cloud/privacy/timeout) from a task request. */
export type RoutingConstraints = NonNullable<TaskRequest["constraints"]>;
/** Routing preferences (e.g. `optimizeFor`) from a task request. */
export type RoutingPreferences = NonNullable<TaskRequest["preferences"]>;
/** Serialization format of a model package (`onnx`, `ort`, `genai`). */
export type ModelPackageFormat = ModelPackage["format"];
/** How a model package's files are supplied to a provider (`registry`, `bundled`, ...). */
export type ModelSourceType = NonNullable<ModelPackage["source"]>["sourceType"];
/** Execution placement a provider declares (`local`, `edge`, `cloud`). */
export type ProviderType = ProviderDescriptor["type"];
/** Cancellation guarantee a provider declares (`hard`, `soft`, `none`). */
export type CancelSemantics = ProviderDescriptor["cancel"];
/** How the engine reaches a provider (`in_process`, `system_service`, `http`, ...). */
export type ProviderTransport = ProviderDescriptor["transport"];

// Per-task narrowings (ADR 016). Code generation cannot express the schema's per-kind
// `if`/`then` requirements, so every task payload is optional on the generated types; these
// aliases restate them for code that has already established the kind.

/** A `text_to_text` request: `prompt` and/or `messages`, never a non-text payload. */
export type TextTaskRequest = TaskRequest & {
  task: { kind: "text_to_text" };
  speech?: never;
  delivery?: never;
};
/** A `text_to_speech` request: the `speech` payload and a playback or artifact delivery. */
export type SpeechTaskRequest = TaskRequest & {
  task: { kind: "text_to_speech" };
  speech: SpeechInput;
  delivery: OutputDeliveryRequest & { mode: "playback" | "artifact" };
  prompt?: never;
  messages?: never;
  generation?: never;
};
/** Inline text output. */
export type TextTaskOutput = TaskOutput & { type: "text"; text: string };
/** Completion of managed playback; carries no media. */
export type PlaybackTaskOutput = TaskOutput & { type: "playback"; playback: PlaybackOutput };
/** A reference to retrievable media (ADR 017). */
export type ArtifactTaskOutput = TaskOutput & { type: "artifact"; artifact: MediaArtifact };
