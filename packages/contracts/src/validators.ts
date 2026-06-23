import Ajv2020 from "ajv/dist/2020.js";
import type { ErrorObject, ValidateFunction } from "ajv";

import type { IndeRunError } from "./generated/inderun-error.js";
import type { HttpRequest } from "./generated/http-request.js";
import type { HttpResponse } from "./generated/http-response.js";
import type { RoutePlan } from "./generated/route-plan.js";
import type { RoutePlannerInput } from "./generated/route-planner-input.js";
import {
  httpRequestSchema,
  httpResponseSchema,
  inderunErrorSchema,
  routePlanSchema,
  routePlannerInputSchema,
  taskRequestSchema,
  taskResultSchema,
  telemetryEventSchema
} from "./generated/index.js";
import type { TaskRequest } from "./generated/task-request.js";
import type { TaskResult } from "./generated/task-result.js";
import type { TelemetryEvent } from "./generated/telemetry-event.js";

type Ajv2020Constructor = typeof import("ajv/dist/2020.js").Ajv2020;

export type ValidationIssue = {
  path: string;
  message: string;
  keyword?: string;
};

const Ajv2020Constructor = Ajv2020 as unknown as Ajv2020Constructor;

const ajv = new Ajv2020Constructor({
  allErrors: true,
  strict: true,
  strictRequired: false,
  validateSchema: true
});

const validateTaskRequestSchema = ajv.compile(taskRequestSchema);
const validateTaskResultSchema = ajv.compile(taskResultSchema);
const validateIndeRunErrorSchema = ajv.compile(inderunErrorSchema);
const validateHttpRequestSchema = ajv.compile(httpRequestSchema);
const validateHttpResponseSchema = ajv.compile(httpResponseSchema);
const validateTelemetryEventSchema = ajv.compile(telemetryEventSchema);
const validateRoutePlannerInputSchema = ajv.compile(routePlannerInputSchema);
const validateRoutePlanSchema = ajv.compile(routePlanSchema);

export function validateTaskRequest(value: unknown): value is TaskRequest {
  return getTaskRequestValidationIssues(value).length === 0;
}

export function validateTaskResult(value: unknown): value is TaskResult {
  return getTaskResultValidationIssues(value).length === 0;
}

export function validateIndeRunError(value: unknown): value is IndeRunError {
  return getIndeRunErrorValidationIssues(value).length === 0;
}

export function validateHttpRequest(value: unknown): value is HttpRequest {
  return getHttpRequestValidationIssues(value).length === 0;
}

export function validateHttpResponse(value: unknown): value is HttpResponse {
  return getHttpResponseValidationIssues(value).length === 0;
}

export function validateTelemetryEvent(value: unknown): value is TelemetryEvent {
  return getTelemetryEventValidationIssues(value).length === 0;
}

export function validateRoutePlannerInput(value: unknown): value is RoutePlannerInput {
  return getRoutePlannerInputValidationIssues(value).length === 0;
}

export function validateRoutePlan(value: unknown): value is RoutePlan {
  return getRoutePlanValidationIssues(value).length === 0;
}

export function getTaskRequestValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskRequestSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getTaskResultValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskResultSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getIndeRunErrorValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateIndeRunErrorSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getHttpRequestValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateHttpRequestSchema, value);
}

export function getHttpResponseValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateHttpResponseSchema, value);
}

export function getTelemetryEventValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTelemetryEventSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getRoutePlannerInputValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateRoutePlannerInputSchema, value);
}

export function getRoutePlanValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateRoutePlanSchema, value);
}

function getValidationIssues(
  validateSchema: ValidateFunction,
  value: unknown,
  options: { forbidInlineSecrets?: boolean } = {}
): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (!validateSchema(value)) {
    issues.push(...formatAjvIssues(validateSchema.errors ?? []));
  }

  if (options.forbidInlineSecrets) {
    issues.push(...findInlineSecretKeys(value));
  }

  return issues;
}

function formatAjvIssues(errors: ErrorObject[]): ValidationIssue[] {
  return errors.map((error) => ({
    path: error.instancePath || "/",
    message: error.message ?? "Invalid value",
    keyword: error.keyword
  }));
}

function findInlineSecretKeys(value: unknown, path = ""): ValidationIssue[] {
  if (Array.isArray(value)) {
    return value.flatMap((item, index) => findInlineSecretKeys(item, `${path}/${index}`));
  }

  if (!value || typeof value !== "object") {
    return [];
  }

  const issues: ValidationIssue[] = [];
  for (const [key, child] of Object.entries(value)) {
    const childPath = `${path}/${escapeJsonPointerSegment(key)}`;
    if (isForbiddenSecretKey(key)) {
      issues.push({
        path: childPath,
        message: "Inline secrets are not allowed; use authContextRef instead.",
        keyword: "forbiddenSecretKey"
      });
    }
    issues.push(...findInlineSecretKeys(child, childPath));
  }

  return issues;
}

function normalizeKey(key: string): string {
  return key.replace(/[^a-z0-9]/gi, "").toLowerCase();
}

function isForbiddenSecretKey(key: string): boolean {
  const normalizedKey = normalizeKey(key);

  if (
    normalizedKey.includes("authorization") ||
    normalizedKey.includes("password") ||
    normalizedKey.includes("secret") ||
    normalizedKey.includes("apikey")
  ) {
    return true;
  }

  if (normalizedKey.includes("api") && normalizedKey.includes("key")) {
    return true;
  }

  return normalizedKey === "token" || normalizedKey.endsWith("token");
}

function escapeJsonPointerSegment(segment: string): string {
  return segment.replaceAll("~", "~0").replaceAll("/", "~1");
}
