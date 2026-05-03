import Ajv2020 from "ajv/dist/2020.js";
import type { ErrorObject, ValidateFunction } from "ajv";

import type { IndeRunError } from "./generated/inderun-error.js";
import {
  inderunErrorSchema,
  taskRequestSchema,
  taskResultSchema
} from "./generated/index.js";
import type { TaskRequest } from "./generated/task-request.js";
import type { TaskResult } from "./generated/task-result.js";

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

export function validateTaskRequest(value: unknown): value is TaskRequest {
  return getTaskRequestValidationIssues(value).length === 0;
}

export function validateTaskResult(value: unknown): value is TaskResult {
  return getTaskResultValidationIssues(value).length === 0;
}

export function validateIndeRunError(value: unknown): value is IndeRunError {
  return getIndeRunErrorValidationIssues(value).length === 0;
}

export function getTaskRequestValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskRequestSchema, value);
}

export function getTaskResultValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskResultSchema, value);
}

export function getIndeRunErrorValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateIndeRunErrorSchema, value);
}

function getValidationIssues(validateSchema: ValidateFunction, value: unknown): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (!validateSchema(value)) {
    issues.push(...formatAjvIssues(validateSchema.errors ?? []));
  }

  issues.push(...findInlineSecretKeys(value));
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
