/* This file was generated from contracts/api/inderun-api.json. Do not edit by hand. */

package app.independo.inderun.sdk.generated

import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.core.ProviderCapabilitySnapshot
import app.independo.inderun.core.StreamRun

interface IndeRunApi {
    /**
     * Executes a Mode 1 (request/response) text-to-text task against a routed provider and returns the completed TaskResult. Routing (local vs. cloud, which provider) is decided internally from TaskRequest.constraints/preferences — the caller does not select a provider directly. Rejects the request up front on validation failure; otherwise throws an IndeRunException (carrying an IndeRunError) if no eligible provider is found or every attempted provider fails. There is no partial or streaming result in this mode: run() either resolves with a complete TaskResult or throws.
     */
    suspend fun run(request: TaskRequest): TaskResult

    /**
     * Executes a Mode 2 (streaming) text-to-text task and returns a handle to the run, its canonical StreamEvent sequence, and a cancel hook. The requested interaction mode is a routing input rather than a filter applied after routing: providers that cannot stream are rejected during planning with a normalized reason, so a stream and a run over the same registry may legitimately resolve to different provider chains. Two failure surfaces exist deliberately — validation and route-selection failures reject this call, since there is no handle to correlate them with yet, while provider failure, cancellation, and completion all arrive as the single terminal StreamEvent in the returned sequence. Fallback is narrower than run()'s: a provider failure is only fallback-eligible before the first content event has been delivered; once one has, the run is committed to that provider and a later failure becomes a terminal error rather than a silent provider swap. Cancellation forecloses both at any commit state and always produces exactly one cancelled outcome.
     */
    suspend fun stream(request: TaskRequest): StreamRun

    /**
     * Returns a live snapshot of every registered provider's static descriptor and current dynamic availability, without executing a task or producing any side effects. Call this before run() when you need to show which providers/models are currently available — for example a settings screen or provider picker. Availability can change between calls (a local model can unload, cloud credentials can expire), so don't cache the result across a run() call.
     */
    suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot>
}
