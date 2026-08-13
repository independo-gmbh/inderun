/* This file was generated from contracts/api/inderun-api.json. Do not edit by hand. */

import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import type { ProviderCapabilitySnapshot } from "../provider.js";

export interface IndeRunApi {
  /**
   * Executes a Mode 1 (request/response) text-to-text task against a routed provider and returns the completed TaskResult. Routing (local vs. cloud, which provider) is decided internally from TaskRequest.constraints/preferences — the caller does not select a provider directly. Rejects the request up front on validation failure; otherwise throws an IndeRunException (carrying an IndeRunError) if no eligible provider is found or every attempted provider fails. There is no partial or streaming result in this mode: run() either resolves with a complete TaskResult or throws.
   */
  run(request: TaskRequest): Promise<TaskResult>;
  /**
   * Returns a live snapshot of every registered provider's static descriptor and current dynamic availability, without executing a task or producing any side effects. Call this before run() when you need to show which providers/models are currently available — for example a settings screen or provider picker. Availability can change between calls (a local model can unload, cloud credentials can expire), so don't cache the result across a run() call.
   */
  checkCapabilities(): Promise<ProviderCapabilitySnapshot[]>;
}
