import type {
  IndeRunError,
  ModelPackage,
  ProviderDescriptor,
  RoutePlan,
  RoutePlannerInput,
  TaskRequest,
  TaskResult
} from "./generated/index.js";

// Convenience aliases derived from the generated schema types, so consumers can
// name individual fields without reaching into the generated index signatures.

/** Contract schema version (e.g. `"1.0"`) carried by every task request. */
export type SchemaVersion = TaskRequest["schemaVersion"];
/** Supported task kinds (currently `"text_to_text"`). */
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
