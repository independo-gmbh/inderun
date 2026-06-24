import type { IndeRunError, RoutePlan, RoutePlannerInput, TaskRequest, TaskResult } from "./generated/index.js";

export type SchemaVersion = TaskRequest["schemaVersion"];
export type TaskKind = TaskRequest["task"]["kind"];
export type FinishReason = TaskResult["finishReason"];
export type IndeRunErrorClass = IndeRunError["errorClass"];
export type SharedRoutePlannerInput = RoutePlannerInput;
export type SharedRoutePlan = RoutePlan;
export type RoutingConstraints = NonNullable<TaskRequest["constraints"]>;
export type RoutingPreferences = NonNullable<TaskRequest["preferences"]>;
