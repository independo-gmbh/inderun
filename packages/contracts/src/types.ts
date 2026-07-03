import type { IndeRunError, RoutePlan, RoutePlannerInput, TaskRequest, TaskResult } from "./generated/index.js";

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
