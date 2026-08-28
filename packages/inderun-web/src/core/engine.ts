import {
  getTaskRequestValidationIssues,
  type StreamEvent,
  type StreamRunHandle,
  type StreamTerminalOutcome,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderCapabilitySnapshot } from "./provider.js";
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

/**
 * Handle returned by IndeRun.stream(). `events` is the canonical StreamEvent
 * sequence for this run, terminating in exactly one terminal StreamEvent per the
 * Event Gate's guarantee. `cancel()` is idempotent: repeated or concurrent calls
 * produce exactly one `cancelled` terminal outcome.
 */
export interface StreamHandleResult {
  handle: StreamRunHandle;
  events: AsyncIterable<StreamEvent>;
  cancel(reason?: string): void;
}

/**
 * Main orchestrator SDK entrypoint class.
 * Validates tasks, executes routing rules based on request constraints and connectivity,
 * triggers provider adapters, and logs timing telemetry.
 */
export class IndeRun implements IndeRunApi {
  private router: Router;
  private telemetryService: TelemetryService;

  /**
   * Initializes the IndeRun instance.
   * @param registry - Registry filled with active providers.
   * @param hostServices - Services wrapping OS interfaces and indicators.
   * @param telemetryService - Optional custom telemetry service listener.
   */
  constructor(
    private registry: ProviderRegistry,
    private hostServices: HostServices,
    telemetryService?: TelemetryService
  ) {
    this.router = new Router(this.registry);
    this.telemetryService =
      telemetryService || this.hostServices.telemetry || new NoOpTelemetryService();
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
    const startTime = this.hostServices.clock ? this.hostServices.clock.now() : Date.now();

    const runId = request.requestId || `run_${Math.random().toString(36).substring(2, 11)}`;

    try {
      // 1. Validate request payload using schema contracts
      const validationIssues = getTaskRequestValidationIssues(request);
      if (validationIssues.length > 0) {
        const message = `Validation failed for TaskRequest: ${validationIssues
          .map((i) => `${i.path} - ${i.message}`)
          .join("; ")}`;
        throw createInternal(message, {
          runId,
          details: { validationIssues }
        });
      }

      // 2. Select the route based on constraints and host capabilities
      const routeSelection = await this.router.selectRoute(request, this.hostServices, "run");
      const providers = [routeSelection.provider, ...routeSelection.fallbackProviders];

      // Emit route_decided event
      this.safeEmit({
        type: "route_decided",
        runId,
        timestamp: this.hostServices.clock ? this.hostServices.clock.now() : Date.now(),
        payload: {
          selectedProviderId: routeSelection.routePlan.selectedProviderId,
          fallbackProviderIds: routeSelection.routePlan.fallbackProviderIds,
          rejectedProviders: routeSelection.routePlan.rejectedProviders,
          fallbackAvailable: providers.length > 1,
          taskKind: request.task.kind,
          explanation: routeSelection.explanation,
          constraints: request.constraints ?? null,
          preferences: request.preferences ?? null,
          plannerSource: routeSelection.plannerSource,
          plannerUnavailableReason: routeSelection.plannerUnavailableReason ?? null
        }
      });

      // 3. Execute the run task using the planned provider chain
      const attemptedProviderIds: string[] = [];
      let lastError: unknown;
      for (const [index, provider] of providers.entries()) {
        const providerId = provider.describe().id;
        attemptedProviderIds.push(providerId);

        try {
          const result = await provider.run(request, {
            runId,
            hostServices: this.hostServices
          });

          const endTime = this.hostServices.clock ? this.hostServices.clock.now() : Date.now();
          const totalMs = endTime - startTime;

          result.runId = runId;
          result.telemetry = {
            ...result.telemetry,
            providerUsed: providerId,
            totalMs
          };

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
          lastError = toIndeRunException(err, {
            providerId,
            runId,
            details: {
              attemptedProviderIds,
              fallbackOccurred: index > 0,
              routePlan: routeSelection.routePlan
            }
          });
        }
      }

      const endTime = this.hostServices.clock ? this.hostServices.clock.now() : Date.now();
      const totalMs = endTime - startTime;
      const exception = toIndeRunException(lastError ?? new Error("No providers were attempted."), {
        runId,
        details: {
          totalMs,
          attemptedProviderIds,
          fallbackOccurred: providers.length > 1,
          routePlan: routeSelection.routePlan
        }
      });

      throw exception;
    } catch (error) {
      const exception = toIndeRunException(error, {
        runId,
        details: {
          totalMs:
            typeof (error as { details?: { totalMs?: number } }).details?.totalMs === "number"
              ? (error as { details?: { totalMs?: number } }).details?.totalMs
              : (this.hostServices.clock ? this.hostServices.clock.now() : Date.now()) - startTime
        }
      });
      const endTime = this.hostServices.clock ? this.hostServices.clock.now() : Date.now();
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
  async stream(request: TaskRequest): Promise<StreamHandleResult> {
    const startTime = this.hostServices.clock ? this.hostServices.clock.now() : Date.now();
    const now = () => (this.hostServices.clock ? this.hostServices.clock.now() : Date.now());
    const runId = request.requestId || `run_${Math.random().toString(36).substring(2, 11)}`;

    const validationIssues = getTaskRequestValidationIssues(request);
    if (validationIssues.length > 0) {
      const message = `Validation failed for TaskRequest: ${validationIssues
        .map((i) => `${i.path} - ${i.message}`)
        .join("; ")}`;
      throw createInternal(message, { runId, details: { validationIssues } });
    }

    // Route selection failures are the one class of stream error that surfaces as a
    // rejected promise instead of a terminal event, so they must still carry the
    // runId — there is no handle for the caller to correlate them with otherwise.
    let routeSelection: RouteSelection;
    try {
      routeSelection = await this.router.selectRoute(request, this.hostServices, "stream");
    } catch (error) {
      throw toIndeRunException(error, { runId });
    }
    const providers = [routeSelection.provider, ...routeSelection.fallbackProviders];

    this.safeEmit({
      type: "route_decided",
      runId,
      timestamp: now(),
      payload: {
        selectedProviderId: routeSelection.routePlan.selectedProviderId,
        fallbackProviderIds: routeSelection.routePlan.fallbackProviderIds,
        rejectedProviders: routeSelection.routePlan.rejectedProviders,
        fallbackAvailable: providers.length > 1,
        taskKind: request.task.kind,
        explanation: routeSelection.explanation,
        constraints: request.constraints ?? null,
        preferences: request.preferences ?? null,
        plannerSource: routeSelection.plannerSource,
        plannerUnavailableReason: routeSelection.plannerUnavailableReason ?? null
      }
    });

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

    async function* run(): AsyncGenerator<StreamEvent> {
      const attemptedProviderIds: string[] = [];
      let committed = false;

      const cancelledOutcome = (partialText: string): StreamTerminalOutcome => {
        const reason =
          typeof controller.signal.reason === "string" ? controller.signal.reason : undefined;
        return {
          outcome: "cancelled",
          runId,
          schemaVersion: "1.0",
          partialText,
          ...(reason !== undefined ? { reason } : {})
        };
      };

      for (const [index, provider] of providers.entries()) {
        if (controller.signal.aborted) {
          break;
        }

        const providerId = provider.describe().id;
        attemptedProviderIds.push(providerId);
        safeEmit({
          type: "stream_attempt_started",
          runId,
          timestamp: now(),
          payload: { providerId, fallbackOccurred: index > 0 }
        });

        let partialText = "";
        try {
          const iterable = (provider as Required<Pick<ProviderAdapter, "stream">>).stream(request, {
            runId,
            hostServices: hostServices,
            signal: controller.signal
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
              partialText = ev.kind === "delta" ? partialText + ev.text : ev.text;
              if (!committed) {
                committed = true;
                safeEmit({
                  type: "stream_attempt_succeeded",
                  runId,
                  timestamp: now(),
                  payload: { providerId, attemptedProviderIds }
                });
              }
              const streamEvent = gate.admit({
                timestamp: now(),
                type: ev.kind === "delta" ? "content_delta" : "content_snapshot",
                payload: { text: ev.text }
              });
              if (streamEvent) yield streamEvent;
              continue;
            }

            // ev.kind === "done"
            const outcome: StreamTerminalOutcome = {
              outcome: "completed",
              runId,
              schemaVersion: "1.0",
              finalText: ev.finalText,
              telemetry: { providerUsed: providerId, totalMs: now() - startTime },
              ...(ev.finishReason !== undefined ? { finishReason: ev.finishReason } : {}),
              ...(ev.usage !== undefined ? { usage: ev.usage } : {})
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
            const terminal = gate.terminate(cancelledOutcome(partialText), now());
            safeEmit({
              type: "stream_cancelled",
              runId,
              timestamp: now(),
              payload: { providerId, attemptedProviderIds }
            });
            if (terminal) yield terminal;
            return;
          }

          // Provider's iterable ended without a terminal "done"/"error" event.
          throw new Error(`Provider '${providerId}' stream ended without a terminal event.`);
        } catch (err) {
          if (controller.signal.aborted) {
            const terminal = gate.terminate(cancelledOutcome(partialText), now());
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

          const outcome: StreamTerminalOutcome = {
            outcome: "error",
            runId,
            schemaVersion: "1.0",
            error: exception.toContractError(),
            partialText
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
        partialText: ""
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
