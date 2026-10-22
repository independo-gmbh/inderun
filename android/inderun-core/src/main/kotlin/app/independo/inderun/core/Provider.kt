package app.independo.inderun.core

import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult

// ProviderDescriptor, ProviderDynamicCapabilities and ProviderCapabilitySnapshot are
// generated from contracts/schemas/provider-*.schema.json into
// app.independo.inderun.contracts, which this module exposes through `api(...)`.

data class RunContext(
    val runId: String,
    val hostServices: HostServices,
    /**
     * The voice the route plan bound this provider to for a speech task: provider-neutral
     * traits the provider must honour when it picks the voice that speaks. Null for tasks
     * without a voice and for providers that do not list their voices, which then choose
     * under the same rule (ADR 016 §4). The engine has re-checked it against the request's
     * privacy policy immediately before the attempt.
     */
    val voice: ProviderVoice? = null,
)

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
