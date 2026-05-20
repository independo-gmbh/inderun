import {
  getTaskRequestValidationIssues,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import { ProviderRegistry } from "./registry.js";
import { Router } from "./router.js";
import { createInternal, toIndeRunException } from "./errors.js";

/**
 * Main orchestrator SDK entrypoint class.
 * Validates tasks, executes routing rules based on execution policies and connectivity,
 * triggers provider adapters, and logs timing telemetry.
 */
export class IndeRun {
  private router: Router;

  /**
   * Initializes the IndeRun instance.
   * @param registry - Registry filled with active providers.
   * @param hostServices - Services wrapping OS interfaces and indicators.
   */
  constructor(
    private registry: ProviderRegistry,
    private hostServices: HostServices
  ) {
    this.router = new Router(this.registry);
  }

  /**
   * Orchestrates the execution of a TaskRequest.
   * Performs JSON Schema validation, selects a provider via routing rules,
   * measures total execution time, and attaches telemetry metadata to the outcome.
   * @param request - The canonical task request containing prompts, tasks, and policies.
   * @returns Canonical task output containing output details and telemetry metadata.
   * @throws {IndeRunException} Standardized error indicating validation, connection, or provider failures.
   */
  async run(request: TaskRequest): Promise<TaskResult> {
    const startTime = this.hostServices.clock
      ? this.hostServices.clock.now()
      : Date.now();

    const runId =
      request.requestId ||
      `run_${Math.random().toString(36).substring(2, 11)}`;

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

      // 2. Select the route based on policy and host capabilities
      const routeSelection = await this.router.selectRoute(
        request,
        this.hostServices
      );
      const provider = routeSelection.provider;

      // 3. Execute the run task on the selected provider
      let result: TaskResult;
      try {
        result = await provider.run(request, { runId });
      } catch (err) {
        const exc = toIndeRunException(err, {
          providerId: provider.describe().id,
          runId
        });
        throw exc;
      }

      // 4. Record timings and finalize telemetry
      const endTime = this.hostServices.clock
        ? this.hostServices.clock.now()
        : Date.now();
      const totalMs = endTime - startTime;

      // Ensure the returned runId matches the engine's orchestrated runId
      result.runId = runId;

      // Ensure standard telemetry fields are present
      result.telemetry = {
        ...result.telemetry,
        providerUsed: provider.describe().id,
        totalMs
      };

      return result;
    } catch (err) {
      const endTime = this.hostServices.clock
        ? this.hostServices.clock.now()
        : Date.now();
      const totalMs = endTime - startTime;

      const exception = toIndeRunException(err, {
        runId,
        details: { totalMs }
      });

      throw exception;
    }
  }
}
