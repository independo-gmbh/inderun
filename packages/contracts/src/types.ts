import type { IndeRunError, TaskRequest, TaskResult } from "./generated/index.js";

export type SchemaVersion = TaskRequest["schemaVersion"];
export type TaskKind = TaskRequest["task"]["kind"];
export type ExecutionPolicy = TaskRequest["policy"]["execution"];
export type FinishReason = TaskResult["finishReason"];
export type IndeRunErrorClass = IndeRunError["errorClass"];
