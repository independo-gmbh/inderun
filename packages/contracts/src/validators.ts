import Ajv2020 from "ajv/dist/2020.js";
import type { ErrorObject, ValidateFunction } from "ajv";

import type { ArtifactReadRequest } from "./generated/artifact-read-request.js";
import type { ExecutionProvenance } from "./generated/execution-provenance.js";
import type { IndeRunError } from "./generated/inderun-error.js";
import type { MediaArtifact } from "./generated/media-artifact.js";
import type { HttpRequest } from "./generated/http-request.js";
import type { HttpResponse } from "./generated/http-response.js";
import type { ModelPackage } from "./generated/model-package.js";
import type { ProviderCapabilitySnapshot } from "./generated/provider-capability-snapshot.js";
import type { ProviderDescriptor } from "./generated/provider-descriptor.js";
import type { ProviderDynamicCapabilities } from "./generated/provider-dynamic-capabilities.js";
import type { RoutePlan } from "./generated/route-plan.js";
import type { RoutePlannerInput } from "./generated/route-planner-input.js";
import {
  artifactReadRequestSchema,
  executionProvenanceSchema,
  httpRequestSchema,
  httpResponseSchema,
  inderunErrorSchema,
  mediaArtifactSchema,
  modelPackageSchema,
  providerCapabilitySnapshotSchema,
  providerDescriptorSchema,
  providerDynamicCapabilitiesSchema,
  routePlanSchema,
  routePlannerInputSchema,
  streamEventSchema,
  streamRunSchema,
  streamTerminalOutcomeSchema,
  taskOutputSchema,
  taskRequestSchema,
  taskResultSchema,
  telemetryEventSchema
} from "./generated/index.js";
import type { StreamEvent } from "./generated/stream-event.js";
import type { StreamRunHandle } from "./generated/stream-run.js";
import type { StreamTerminalOutcome } from "./generated/stream-terminal-outcome.js";
import type { TaskOutput } from "./generated/task-output.js";
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

// Referenced by `$ref` from every schema that carries provenance, so it has to be known
// to Ajv before any of them compiles. Compiling it registers it under its `$id`.
const validateExecutionProvenanceSchema = ajv.compile(executionProvenanceSchema);
// Likewise, the provider descriptor and dynamic capabilities are referenced from the
// capability snapshot and the route-planner input.
const validateProviderDescriptorSchema = ajv.compile(providerDescriptorSchema);
const validateProviderDynamicCapabilitiesSchema = ajv.compile(providerDynamicCapabilitiesSchema);
const validateProviderCapabilitySnapshotSchema = ajv.compile(providerCapabilitySnapshotSchema);
// The normalized output (and the media artifact it references) is shared by the result
// and both terminal-outcome copies.
const validateMediaArtifactSchema = ajv.compile(mediaArtifactSchema);
const validateTaskOutputSchema = ajv.compile(taskOutputSchema);
const validateArtifactReadRequestSchema = ajv.compile(artifactReadRequestSchema);
const validateTaskRequestSchema = ajv.compile(taskRequestSchema);
const validateTaskResultSchema = ajv.compile(taskResultSchema);
const validateIndeRunErrorSchema = ajv.compile(inderunErrorSchema);
const validateHttpRequestSchema = ajv.compile(httpRequestSchema);
const validateHttpResponseSchema = ajv.compile(httpResponseSchema);
const validateTelemetryEventSchema = ajv.compile(telemetryEventSchema);
const validateRoutePlannerInputSchema = ajv.compile(routePlannerInputSchema);
const validateRoutePlanSchema = ajv.compile(routePlanSchema);
const validateModelPackageSchema = ajv.compile(modelPackageSchema);
const validateStreamRunHandleSchema = ajv.compile(streamRunSchema);
const validateStreamEventSchema = ajv.compile(streamEventSchema);
const validateStreamTerminalOutcomeSchema = ajv.compile(streamTerminalOutcomeSchema);

export function validateTaskRequest(value: unknown): value is TaskRequest {
  return getTaskRequestValidationIssues(value).length === 0;
}

export function validateTaskResult(value: unknown): value is TaskResult {
  return getTaskResultValidationIssues(value).length === 0;
}

export function validateTaskOutput(value: unknown): value is TaskOutput {
  return getTaskOutputValidationIssues(value).length === 0;
}

export function validateMediaArtifact(value: unknown): value is MediaArtifact {
  return getMediaArtifactValidationIssues(value).length === 0;
}

export function validateArtifactReadRequest(value: unknown): value is ArtifactReadRequest {
  return getArtifactReadRequestValidationIssues(value).length === 0;
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

export function validateModelPackage(value: unknown): value is ModelPackage {
  return getModelPackageValidationIssues(value).length === 0;
}

export function validateProviderDescriptor(value: unknown): value is ProviderDescriptor {
  return getProviderDescriptorValidationIssues(value).length === 0;
}

export function validateProviderDynamicCapabilities(
  value: unknown
): value is ProviderDynamicCapabilities {
  return getProviderDynamicCapabilitiesValidationIssues(value).length === 0;
}

export function validateProviderCapabilitySnapshot(
  value: unknown
): value is ProviderCapabilitySnapshot {
  return getProviderCapabilitySnapshotValidationIssues(value).length === 0;
}

export function validateStreamRunHandle(value: unknown): value is StreamRunHandle {
  return getStreamRunHandleValidationIssues(value).length === 0;
}

export function validateStreamEvent(value: unknown): value is StreamEvent {
  return getStreamEventValidationIssues(value).length === 0;
}

export function validateStreamTerminalOutcome(value: unknown): value is StreamTerminalOutcome {
  return getStreamTerminalOutcomeValidationIssues(value).length === 0;
}

export function getTaskRequestValidationIssues(value: unknown): ValidationIssue[] {
  const issues = getValidationIssues(validateTaskRequestSchema, value, {
    forbidInlineSecrets: true
  });

  issues.push(...findRoutingConstraintIssues(value));
  return issues;
}

export function getTaskResultValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskResultSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getTaskOutputValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateTaskOutputSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getMediaArtifactValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateMediaArtifactSchema, value);
}

export function getArtifactReadRequestValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateArtifactReadRequestSchema, value);
}

export function getIndeRunErrorValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateIndeRunErrorSchema, value, {
    forbidInlineSecrets: true
  });
}

export function validateExecutionProvenance(value: unknown): value is ExecutionProvenance {
  return getExecutionProvenanceValidationIssues(value).length === 0;
}

export function getExecutionProvenanceValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateExecutionProvenanceSchema, value, {
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

export function getModelPackageValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateModelPackageSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getProviderDescriptorValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateProviderDescriptorSchema, value);
}

export function getProviderDynamicCapabilitiesValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateProviderDynamicCapabilitiesSchema, value);
}

export function getProviderCapabilitySnapshotValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateProviderCapabilitySnapshotSchema, value);
}

export function getStreamRunHandleValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateStreamRunHandleSchema, value);
}

export function getStreamEventValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateStreamEventSchema, value, {
    forbidInlineSecrets: true
  });
}

export function getStreamTerminalOutcomeValidationIssues(value: unknown): ValidationIssue[] {
  return getValidationIssues(validateStreamTerminalOutcomeSchema, value, {
    forbidInlineSecrets: true
  });
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

function findRoutingConstraintIssues(value: unknown): ValidationIssue[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return [];
  }

  const request = value as {
    constraints?: {
      cloud?: string;
      privacy?: string;
    };
  };

  const constraints = request.constraints;
  if (!constraints) {
    return [];
  }

  const issues: ValidationIssue[] = [];

  if (constraints.privacy === "local_required" && constraints.cloud === "required") {
    issues.push({
      path: "/constraints",
      message: "privacy=local_required conflicts with cloud=required.",
      keyword: "routingConstraintConflict"
    });
  }

  if (constraints.privacy === "cloud_required" && constraints.cloud === "forbidden") {
    issues.push({
      path: "/constraints",
      message: "privacy=cloud_required conflicts with cloud=forbidden.",
      keyword: "routingConstraintConflict"
    });
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
