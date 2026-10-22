import {
  type ArtifactReadRequest,
  getArtifactReadRequestValidationIssues,
  getTaskRequestValidationIssues,
  type MediaArtifact,
  type StreamEvent,
  type StreamRunHandle,
  type StreamTerminalOutcome,
  type TaskOutput,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderCapabilitySnapshot, StreamRun } from "./provider.js";
import type { IndeRunApi } from "./generated/inderun-api.js";
import { ProviderRegistry } from "./registry.js";
import { type RouteSelection, Router } from "./router.js";
import {
  createCapabilityMismatch,
  createInternal,
  createUnavailable,
  toIndeRunException
} from "./errors.js";
import { type TelemetryEvent, type TelemetryService, NoOpTelemetryService } from "./telemetry.js";
import { EventGate } from "./event-gate.js";
import {
  AUTO_MODEL_PROFILE,
  type ModelProfiles,
  type ResolvedModelProfile,
  resolveModelProfile,
  validateModelProfiles
} from "./model-profiles.js";
import { ProvenanceRecorder } from "./provenance.js";
import {
  checkOutput,
  type OutputDelivery,
  recheckBoundVoice,
  taskProfileFor
} from "./task-profiles.js";
import {
  type ArtifactChunk,
  type ArtifactLimits,
  ArtifactStore,
  type AttemptArtifacts
} from "./artifacts.js";

/**
 * @deprecated Renamed to `StreamRun`, which is the name the generated
 * `IndeRunApi` surface and the Swift/Kotlin SDKs use. Kept as an alias so the
 * rename is not a breaking change.
 */
export type StreamHandleResult = StreamRun;

/**
 * Optional engine configuration.
 */
export interface IndeRunOptions {
  /**
   * Telemetry listener. Defaults to the host's telemetry service, then to a no-op.
   */
  telemetryService?: TelemetryService;
  /**
   * Named model profiles requests can route within (`TaskRequest.modelProfile`).
   * Each maps a profile name to an ordered list of target (provider instance) ids.
   * `"auto"` is built in and cannot be redefined. See `docs/architecture/api-layering.md`.
   */
  modelProfiles?: ModelProfiles;
  /**
   * Size limits of the engine's in-memory artifact store (ADR 017). Defaults: 16 MiB per
   * artifact, 64 MiB in total, 1 MiB per `readArtifact` call.
   */
  artifacts?: ArtifactLimits;
}

/**
 * Main orchestrator SDK entrypoint class.
 * Validates tasks, executes routing rules based on request constraints and connectivity,
 * triggers provider adapters, and logs timing telemetry.
 */
export class IndeRun implements IndeRunApi {
  private router: Router;
  private readonly artifacts: ArtifactStore;
  private telemetryService: TelemetryService;
  private modelProfiles: ModelProfiles;

  /**
   * Initializes the IndeRun instance.
   * @param registry - Registry filled with active providers.
   * @param hostServices - Services wrapping OS interfaces and indicators.
   * @param options - Optional telemetry listener and model profiles.
   * @throws {Error} If a model profile is malformed (see {@link validateModelProfiles}).
   */
  constructor(
    private registry: ProviderRegistry,
    private hostServices: HostServices,
    options: IndeRunOptions = {}
  ) {
    this.router = new Router(this.registry);
    this.telemetryService =
      options.telemetryService || this.hostServices.telemetry || new NoOpTelemetryService();
    this.modelProfiles = options.modelProfiles ?? {};
    validateModelProfiles(this.modelProfiles);
    this.artifacts = new ArtifactStore(options.artifacts);
  }

  /**
   * Validates the request against the schema and resolves its model profile.
   * Both failures are request validation errors: they are reported before any
   * provider is probed, with the offending fields in `details.validationIssues`.
   */
  private validateRequest(request: TaskRequest, runId: string): ResolvedModelProfile {
    const validationIssues = getTaskRequestValidationIssues(request);
    if (validationIssues.length === 0 && taskProfileFor(request.task.kind) === undefined) {
      validationIssues.push({
        path: "/task/kind",
        message: `task kind "${request.task.kind}" is not supported by this engine`
      });
    }
    if (validationIssues.length === 0) {
      const resolved = resolveModelProfile(this.modelProfiles, request.modelProfile);
      if (resolved.known) {
        return resolved.profile;
      }
      validationIssues.push({
        path: "/modelProfile",
        message: `unknown model profile "${request.modelProfile}"; configure it in the engine's modelProfiles`
      });
    }
    const message = `Validation failed for TaskRequest: ${validationIssues
      .map((i) => `${i.path} - ${i.message}`)
      .join("; ")}`;
    throw createInternal(message, { runId, details: { validationIssues } });
  }

  /**
   * Current time from the host clock, falling back to wall-clock time when the
   * host does not supply one.
   */
  private now(): number {
    return this.hostServices.clock ? this.hostServices.clock.now() : Date.now();
  }

  /**
   * Emits `route_decided` for a completed route selection. Shared by `run()` and
   * `stream()`: the payload is identical for both modes, and the interaction
   * mode is already reflected in the plan the router returned.
   */
  private emitRouteDecided(
    runId: string,
    request: TaskRequest,
    routeSelection: RouteSelection,
    providerCount: number
  ): void {
    this.safeEmit({
      type: "route_decided",
      runId,
      timestamp: this.now(),
      payload: {
        selectedProviderId: routeSelection.routePlan.selectedProviderId,
        fallbackProviderIds: routeSelection.routePlan.fallbackProviderIds,
        rejectedProviders: routeSelection.routePlan.rejectedProviders,
        fallbackAvailable: providerCount > 1,
        taskKind: request.task.kind,
        modelProfile: request.modelProfile ?? "auto",
        constraints: request.constraints ?? null,
        preferences: request.preferences ?? null,
        explanation: routeSelection.explanation
      }
    });
  }

  /**
   * Safely emits a telemetry event by swallowing any internal logging/telemetry system errors.
   * @param event - The telemetry event to emit.
   */
  private safeEmit(event: TelemetryEvent): void {
    try {
      this.telemetryService.emit(event);
    } catch (err) {
      // Telemetry failures must never disrupt primary execution flows.
      console.warn("[IndeRun] Telemetry service emission failed:", err);
    }
  }

  /**
   * Returns a stable, generic description of an error class for privacy-preserving telemetry.
   * @param errorClass - The taxonomy classification of the exception.
   */
  private getStableMessage(errorClass: string): string {
    switch (errorClass) {
      case "CapabilityMismatch":
        return "Provider capability mismatch.";
      case "Offline":
        return "Device is offline.";
      case "AuthError":
        return "Authentication failed.";
      case "RateLimited":
        return "Rate limit exceeded.";
      case "Timeout":
        return "Execution timed out.";
      case "Unavailable":
        return "Provider is unavailable.";
      case "Internal":
      default:
        return "An internal engine error occurred.";
    }
  }

  /**
   * Orchestrates the execution of a TaskRequest.
   * Performs JSON Schema validation, selects a provider via routing rules,
   * measures total execution time, and attaches telemetry metadata to the outcome.
   * @param request - The canonical task request containing prompts, tasks, and constraints.
   * @returns Canonical task output containing output details and telemetry metadata.
   * @throws {IndeRunException} Standardized error indicating validation, connection, or provider failures.
   */
  async run(request: TaskRequest): Promise<TaskResult> {
    const startTime = this.now();

    const runId = request.requestId || `run_${Math.random().toString(36).substring(2, 11)}`;
    const provenance = new ProvenanceRecorder(request.modelProfile ?? AUTO_MODEL_PROFILE);
    // The provider a failed run had committed to, which the failure is attributed to.
    let committedProvider: ProviderAdapter | undefined;

    try {
      // 1. Validate request payload using schema contracts and resolve its model profile
      const modelProfile = this.validateRequest(request, runId);

      // 2. Select the route based on constraints, model profile, and host capabilities
      const routeSelection = await this.router.selectRoute(
        request,
        this.hostServices,
        "run",
        modelProfile
      );
      const providers = [routeSelection.provider, ...routeSelection.fallbackProviders];
      provenance.routed(routeSelection.routePlan);
      const delivery = taskProfileFor(request.task.kind)!.delivery(request);

      this.emitRouteDecided(runId, request, routeSelection, providers.length);

      // 3. Execute the run task using the planned provider chain. An attempt that committed
      // (see RunContext.commit) ends the chain: its failure is the run's failure.
      const attemptedProviderIds: string[] = [];
      let lastError: unknown;
      for (const [index, provider] of providers.entries()) {
        const providerId = provider.describe().id;
        const voice = routeSelection.candidates[index]?.voice;
        attemptedProviderIds.push(providerId);
        let committed = false;
        // Closed when the attempt ends: a provider callback that fires after the run moved
        // on must not be told it may start, say, audible playback.
        let attemptOpen = true;
        const commit = () => {
          if (!attemptOpen) return false;
          committed = true;
          return true;
        };
        const attemptArtifacts = this.artifacts.attempt(commit);
        let keptArtifactId: string | undefined;

        try {
          const refusal = recheckBoundVoice(request, providerId, voice);
          if (refusal !== undefined) throw refusal;

          const result = await provider.run(request, {
            runId,
            hostServices: this.hostServices,
            ...(voice !== undefined ? { voice } : {}),
            commit,
            artifacts: attemptArtifacts
          });
          result.output = this.normalizeOutput(
            request,
            delivery,
            result.output,
            providerId,
            attemptArtifacts
          );
          keptArtifactId = result.output.artifact?.id;

          const endTime = this.now();
          const totalMs = endTime - startTime;

          result.runId = runId;
          result.telemetry = {
            ...result.telemetry,
            providerUsed: providerId,
            totalMs
          };
          provenance.attempted(providerId, "succeeded", undefined, committed);
          result.provenance = provenance.build(provider.describe(), result.telemetry.reportedModel);

          this.safeEmit({
            type: "attempt_succeeded",
            runId,
            timestamp: endTime,
            payload: {
              providerId,
              durationMs: totalMs,
              fallbackOccurred: index > 0,
              attemptedProviderIds
            }
          });

          return result;
        } catch (err) {
          const attemptError = toIndeRunException(err, {
            providerId,
            runId,
            details: {
              attemptedProviderIds,
              fallbackOccurred: index > 0,
              routePlan: routeSelection.routePlan
            }
          });
          provenance.attempted(providerId, "failed", attemptError.errorClass, committed);
          lastError = attemptError;
          if (committed) {
            committedProvider = provider;
            break;
          }
        } finally {
          attemptOpen = false;
          attemptArtifacts.release(keptArtifactId);
        }
      }

      const endTime = this.now();
      const totalMs = endTime - startTime;
      const exception = toIndeRunException(lastError ?? new Error("No providers were attempted."), {
        runId,
        details: {
          totalMs,
          attemptedProviderIds,
          fallbackOccurred: attemptedProviderIds.length > 1,
          routePlan: routeSelection.routePlan
        }
      });

      throw exception;
    } catch (error) {
      const normalized = toIndeRunException(error, {
        runId,
        details: {
          totalMs:
            typeof (error as { details?: { totalMs?: number } }).details?.totalMs === "number"
              ? (error as { details?: { totalMs?: number } }).details?.totalMs
              : this.now() - startTime
        }
      });
      // A routing refusal throws before any attempt; its rejections travel on the details.
      provenance.routingFailed(normalized.details);
      // No attempt produced the result, so the outcome is attributed to no provider -- unless
      // the run had committed to one, which then owns the failure.
      const exception = normalized.withProvenance(provenance.build(committedProvider?.describe()));
      const endTime = this.now();
      const totalMs =
        typeof (exception as { details?: { totalMs?: number } }).details?.totalMs === "number"
          ? (exception as { details?: { totalMs?: number } }).details?.totalMs
          : endTime - startTime;

      this.safeEmit({
        type: "attempt_failed",
        runId,
        timestamp: endTime,
        payload: {
          providerId: exception.providerId ?? null,
          durationMs: totalMs,
          errorClass: exception.errorClass,
          message: this.getStableMessage(exception.errorClass)
        }
      });

      throw exception;
    }
  }

  /**
   * Orchestrates a Mode 2 streaming execution of a TaskRequest.
   *
   * Routes through the same planner as run(), asking it for a `stream` route: the
   * planner rejects providers that do not declare `supports.streaming` or whose
   * dynamic capability snapshot says they cannot stream here, and reports why. The
   * whole returned chain is therefore mode-compatible and subject to the same
   * privacy, locality, availability, and policy constraints as a Mode 1 route.
   *
   * Fallback to the next provider is allowed only before the first content event
   * has been admitted for the run; once one has been delivered, the run is
   * committed to that provider and any later provider failure becomes a terminal
   * error outcome rather than a silent provider swap — partial output spliced from
   * two providers is undetectable to the caller. Cancellation always forecloses
   * fallback, regardless of commit state, and is idempotent.
   * @param request - The canonical task request containing prompts, tasks, and constraints.
   * @throws {IndeRunException} If validation fails or no eligible streaming provider exists.
   */
  async stream(request: TaskRequest): Promise<StreamRun> {
    const startTime = this.now();
    const now = () => this.now();
    const runId = request.requestId || `run_${Math.random().toString(36).substring(2, 11)}`;
    const provenance = new ProvenanceRecorder(request.modelProfile ?? AUTO_MODEL_PROFILE);

    let modelProfile: ResolvedModelProfile;
    try {
      modelProfile = this.validateRequest(request, runId);
    } catch (error) {
      throw toIndeRunException(error, { runId }).withProvenance(provenance.build());
    }

    // Route selection failures are the one class of stream error that surfaces as a
    // rejected promise instead of a terminal event, so they must still carry the
    // runId — there is no handle for the caller to correlate them with otherwise.
    let routeSelection: RouteSelection;
    try {
      routeSelection = await this.router.selectRoute(
        request,
        this.hostServices,
        "stream",
        modelProfile
      );
    } catch (error) {
      const exception = toIndeRunException(error, { runId });
      provenance.routingFailed(exception.details);
      throw exception.withProvenance(provenance.build());
    }
    const providers = [routeSelection.provider, ...routeSelection.fallbackProviders];
    provenance.routed(routeSelection.routePlan);

    this.emitRouteDecided(runId, request, routeSelection, providers.length);

    // Defensive only: streaming eligibility is decided by the route planner, which
    // throws with its own rejection reasons when nothing can stream. Reaching here
    // means a planned provider was unregistered between planning and selection.
    if (providers.length === 0) {
      throw createCapabilityMismatch("No eligible provider supports streaming for this request.", {
        runId,
        details: { taskKind: request.task.kind }
      });
    }

    const controller = new AbortController();
    const gate = new EventGate(runId);
    const hostServices = this.hostServices;
    const safeEmit = this.safeEmit.bind(this);
    const getStableMessage = this.getStableMessage.bind(this);

    const handle: StreamRunHandle = {
      runId,
      schemaVersion: "1.0",
      startedAt: startTime,
      providerId: providers[0]!.describe().id
    };

    const delivery = taskProfileFor(request.task.kind)!.delivery(request);
    const textRun = delivery === "inline";
    const artifacts = this.artifacts;
    const normalizeOutput = this.normalizeOutput.bind(this);

    async function* run(): AsyncGenerator<StreamEvent> {
      const attemptedProviderIds: string[] = [];
      // Set once, by whichever comes first in an attempt: the provider's commit(), its first
      // admitted content event, or its result handoff. After it no other provider is tried.
      let committed = false;
      // Whether the committed attempt was managed playback that may have been heard.
      let playbackCommitted = false;

      const cancelledOutcome = (
        partialText: string,
        cancelledProvider?: ProviderAdapter
      ): StreamTerminalOutcome => {
        const reason =
          typeof controller.signal.reason === "string" ? controller.signal.reason : undefined;
        if (cancelledProvider !== undefined) {
          provenance.attempted(cancelledProvider.describe().id, "cancelled", undefined, committed);
        }
        return {
          outcome: "cancelled",
          runId,
          schemaVersion: "1.0",
          // A text run reports what it delivered; committed playback reports that it played.
          // An uncommitted non-text run produced nothing to report.
          ...(textRun ? { partialText } : {}),
          ...(playbackCommitted ? { output: { type: "playback" as const, playback: {} } } : {}),
          ...(reason !== undefined ? { reason } : {}),
          provenance: provenance.build(cancelledProvider?.describe())
        };
      };

      for (const [index, provider] of providers.entries()) {
        if (controller.signal.aborted) {
          break;
        }

        const providerId = provider.describe().id;
        const voice = routeSelection.candidates[index]?.voice;
        attemptedProviderIds.push(providerId);
        safeEmit({
          type: "stream_attempt_started",
          runId,
          timestamp: now(),
          payload: { providerId, fallbackOccurred: index > 0 }
        });

        const markCommitted = () => {
          if (committed) return;
          committed = true;
          playbackCommitted = delivery === "playback";
          safeEmit({
            type: "stream_attempt_succeeded",
            runId,
            timestamp: now(),
            payload: { providerId, attemptedProviderIds }
          });
        };

        // Closed when the attempt ends. A provider callback that fires after the run fell back
        // must neither start audio nor commit the attempt that replaced this one.
        let attemptOpen = true;
        const commit = () => {
          if (!attemptOpen || controller.signal.aborted || gate.isTerminated()) return false;
          markCommitted();
          return true;
        };
        const attemptArtifacts = artifacts.attempt(commit);
        let keptArtifactId: string | undefined;

        let partialText = "";
        try {
          const refusal = recheckBoundVoice(request, providerId, voice);
          if (refusal !== undefined) throw refusal;

          const iterable = (provider as Required<Pick<ProviderAdapter, "stream">>).stream(request, {
            runId,
            hostServices: hostServices,
            signal: controller.signal,
            ...(voice !== undefined ? { voice } : {}),
            commit,
            artifacts: attemptArtifacts
          });

          let terminatedInLoop = false;
          for await (const ev of iterable) {
            if (controller.signal.aborted) {
              break;
            }

            if (ev.kind === "error") {
              throw ev.error;
            }

            if (ev.kind === "delta" || ev.kind === "snapshot") {
              // Content events are text-only (ADR 016 §5).
              if (!textRun) {
                throw checkOutput(request, delivery, { type: "text", text: "" }, providerId)!;
              }
              partialText = ev.kind === "delta" ? partialText + ev.text : ev.text;
              markCommitted();
              const streamEvent = gate.admit({
                timestamp: now(),
                type: ev.kind === "delta" ? "content_delta" : "content_snapshot",
                payload: { text: ev.text }
              });
              if (streamEvent) yield streamEvent;
              continue;
            }

            // ev.kind === "done" (text) or "result" (any task): the run's final output.
            const output = normalizeOutput(
              request,
              delivery,
              ev.kind === "done" ? { type: "text" as const, text: ev.finalText } : ev.output,
              providerId,
              attemptArtifacts
            );
            keptArtifactId = output.artifact?.id;
            markCommitted();
            provenance.attempted(providerId, "succeeded", undefined, committed);
            const outcome: StreamTerminalOutcome = {
              outcome: "completed",
              runId,
              schemaVersion: "1.0",
              ...(ev.kind === "done"
                ? { finalText: ev.finalText }
                : output.type === "text"
                  ? { finalText: output.text!, output }
                  : { output }),
              telemetry: { providerUsed: providerId, totalMs: now() - startTime },
              ...(ev.finishReason !== undefined ? { finishReason: ev.finishReason } : {}),
              ...(ev.kind === "done" && ev.usage !== undefined ? { usage: ev.usage } : {}),
              provenance: provenance.build(provider.describe(), ev.reportedModel)
            };
            const terminal = gate.terminate(outcome, now());
            safeEmit({
              type: "stream_completed",
              runId,
              timestamp: now(),
              payload: { providerId, durationMs: now() - startTime, attemptedProviderIds }
            });
            terminatedInLoop = true;
            if (terminal) yield terminal;
            return;
          }

          if (terminatedInLoop) {
            return;
          }

          if (controller.signal.aborted) {
            attemptArtifacts.release();
            const terminal = gate.terminate(cancelledOutcome(partialText, provider), now());
            safeEmit({
              type: "stream_cancelled",
              runId,
              timestamp: now(),
              payload: { providerId, attemptedProviderIds }
            });
            if (terminal) yield terminal;
            return;
          }

          // Provider's iterable ended without a terminal "done"/"result"/"error" event.
          throw new Error(`Provider '${providerId}' stream ended without a terminal event.`);
        } catch (err) {
          if (controller.signal.aborted) {
            attemptArtifacts.release();
            const terminal = gate.terminate(cancelledOutcome(partialText, provider), now());
            safeEmit({
              type: "stream_cancelled",
              runId,
              timestamp: now(),
              payload: { providerId, attemptedProviderIds }
            });
            if (terminal) yield terminal;
            return;
          }

          const exception = toIndeRunException(err, {
            providerId,
            runId,
            details: { attemptedProviderIds }
          });
          provenance.attempted(providerId, "failed", exception.errorClass, committed);

          if (!committed) {
            safeEmit({
              type: "stream_attempt_failed",
              runId,
              timestamp: now(),
              payload: {
                providerId,
                errorClass: exception.errorClass,
                message: getStableMessage(exception.errorClass)
              }
            });
            continue;
          }

          // Committed: the failure belongs to this provider, not to the chain.
          attemptArtifacts.release();
          const outcome: StreamTerminalOutcome = {
            outcome: "error",
            runId,
            schemaVersion: "1.0",
            error: exception.toContractError(),
            ...(textRun ? { partialText } : {}),
            provenance: provenance.build(provider.describe())
          };
          const terminal = gate.terminate(outcome, now());
          safeEmit({
            type: "stream_failed",
            runId,
            timestamp: now(),
            payload: {
              providerId,
              errorClass: exception.errorClass,
              message: getStableMessage(exception.errorClass),
              attemptedProviderIds
            }
          });
          if (terminal) yield terminal;
          return;
        } finally {
          attemptOpen = false;
          attemptArtifacts.release(keptArtifactId);
        }
      }

      // Every provider failed pre-commit, or cancellation landed before any attempt started.
      if (controller.signal.aborted) {
        const terminal = gate.terminate(cancelledOutcome(""), now());
        safeEmit({
          type: "stream_cancelled",
          runId,
          timestamp: now(),
          payload: { attemptedProviderIds }
        });
        if (terminal) yield terminal;
        return;
      }

      const exception = createUnavailable("All eligible streaming providers failed.", {
        runId,
        details: { attemptedProviderIds }
      });
      const outcome: StreamTerminalOutcome = {
        outcome: "error",
        runId,
        schemaVersion: "1.0",
        error: exception.toContractError(),
        ...(textRun ? { partialText: "" } : {}),
        provenance: provenance.build()
      };
      const terminal = gate.terminate(outcome, now());
      safeEmit({
        type: "stream_failed",
        runId,
        timestamp: now(),
        payload: {
          errorClass: exception.errorClass,
          message: getStableMessage(exception.errorClass),
          attemptedProviderIds
        }
      });
      if (terminal) yield terminal;
    }

    return { handle, events: run(), cancel: (reason?: string) => controller.abort(reason) };
  }

  /**
   * Reports each registered provider's static descriptor and current dynamic capability check,
   * without executing a task. Useful for UI that shows live provider availability before a run.
   */
  async readArtifact(request: ArtifactReadRequest): Promise<ArtifactChunk> {
    const validationIssues = getArtifactReadRequestValidationIssues(request);
    if (validationIssues.length > 0) {
      const message = `Validation failed for ArtifactReadRequest: ${validationIssues
        .map((i) => `${i.path} - ${i.message}`)
        .join("; ")}`;
      throw createInternal(message, { details: { validationIssues } });
    }
    return this.artifacts.read(request);
  }

  async disposeArtifact(artifact: MediaArtifact): Promise<void> {
    if (artifact.owner === "engine") {
      this.artifacts.dispose(artifact.id);
    }
  }

  /**
   * Checks that an artifact in a provider's output is one this attempt produced, swaps in the
   * reference the store holds, and only then checks the output against the requested delivery:
   * the artifact's media type, size and ownership are the engine's record rather than the
   * provider's claim.
   */
  private normalizeOutput(
    request: TaskRequest,
    delivery: OutputDelivery,
    output: TaskOutput | undefined,
    providerId: string,
    attemptArtifacts: AttemptArtifacts
  ): TaskOutput {
    let resolved = output;
    if (output?.artifact !== undefined) {
      if (!attemptArtifacts.owns(output.artifact.id)) {
        throw createInternal(
          `Provider '${providerId}' returned an artifact it did not hand over in this attempt.`,
          { providerId, details: { code: "output_mismatch" } }
        );
      }
      resolved = { ...output, artifact: this.artifacts.reference(output.artifact.id)! };
    }
    const mismatch = checkOutput(request, delivery, resolved, providerId);
    if (mismatch !== undefined) throw mismatch;
    return resolved!;
  }

  async checkCapabilities(): Promise<ProviderCapabilitySnapshot[]> {
    return Promise.all(
      this.registry.list().map(async (provider) => ({
        providerId: provider.describe().id,
        descriptor: provider.describe(),
        capabilities: await provider.capabilities(this.hostServices)
      }))
    );
  }
}
