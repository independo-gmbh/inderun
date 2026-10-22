/**
 * Canonical IndeRun contracts for TypeScript (`@independo/inderun-contracts`).
 *
 * Everything here derives from the JSON Schemas in `contracts/schemas/`, which are
 * the single source of truth across all four languages — the TypeScript types
 * below, the Kotlin and Swift contract models, and the Rust route-core model are
 * all generated from them by `pnpm generate`. Do not hand-edit anything under
 * `src/generated/`; change the schema and regenerate.
 *
 * Apps normally do not depend on this package directly: the SDKs re-export the
 * contract types their own signatures use. Reach for it when you need the schemas
 * themselves or the runtime validators.
 */

/** The generated request/response, streaming, routing, provider-capability, and telemetry models. */
export type * from "./generated/index.js";

/** The JSON Schemas those models were generated from, for runtime use. */
export {
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
/**
 * Ajv-backed validators for each contract. The `get*ValidationIssues` form returns
 * a list of human-readable issues (empty when valid); the `validate*` form is the
 * boolean type guard.
 */
export {
  getArtifactReadRequestValidationIssues,
  getExecutionProvenanceValidationIssues,
  getHttpRequestValidationIssues,
  getHttpResponseValidationIssues,
  getIndeRunErrorValidationIssues,
  getMediaArtifactValidationIssues,
  getModelPackageValidationIssues,
  getProviderCapabilitySnapshotValidationIssues,
  getProviderDescriptorValidationIssues,
  getProviderDynamicCapabilitiesValidationIssues,
  getRoutePlanValidationIssues,
  getRoutePlannerInputValidationIssues,
  getStreamEventValidationIssues,
  getStreamRunHandleValidationIssues,
  getStreamTerminalOutcomeValidationIssues,
  getTaskOutputValidationIssues,
  getTaskRequestValidationIssues,
  getTaskResultValidationIssues,
  getTelemetryEventValidationIssues,
  validateExecutionProvenance,
  validateHttpRequest,
  validateHttpResponse,
  validateIndeRunError,
  validateMediaArtifact,
  validateModelPackage,
  validateProviderCapabilitySnapshot,
  validateProviderDescriptor,
  validateProviderDynamicCapabilities,
  validateRoutePlan,
  validateRoutePlannerInput,
  validateStreamEvent,
  validateStreamRunHandle,
  validateStreamTerminalOutcome,
  validateTaskOutput,
  validateTaskRequest,
  validateTaskResult,
  validateTelemetryEvent,
  validateArtifactReadRequest,
  type ValidationIssue
} from "./validators.js";
/**
 * Narrowed aliases over the generated models: the closed enums the SDKs switch on,
 * and the routing input/output shapes under the names the engines use.
 */
export type {
  CancelSemantics,
  FinishReason,
  IndeRunErrorClass,
  ArtifactTaskOutput,
  ModelPackageFormat,
  ModelSourceType,
  PlaybackTaskOutput,
  ProviderTransport,
  ProviderType,
  SchemaVersion,
  SharedRoutePlan,
  SharedRoutePlannerInput,
  SpeechTaskRequest,
  TaskKind,
  TextTaskOutput,
  TextTaskRequest,
  RoutingConstraints,
  RoutingPreferences
} from "./types.js";

/**
 * The host-services contract: the platform capabilities an SDK reads and calls
 * through. Defined here rather than per-SDK so the three platforms expose the
 * same seams.
 */
export type {
  AbortSignalLike,
  ConnectivityService,
  ThermalState,
  DeviceConstraintsService,
  SecureStorageService,
  ClockService,
  HttpClientService,
  HttpStreamResponse,
  HttpStreamingClientService,
  TelemetryEventType,
  TelemetryService,
  HostServices
} from "./host.js";
