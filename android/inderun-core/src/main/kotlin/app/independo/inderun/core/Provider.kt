package app.independo.inderun.core

import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult

// ProviderDescriptor, ProviderDynamicCapabilities and ProviderCapabilitySnapshot are
// generated from contracts/schemas/provider-*.schema.json into
// app.independo.inderun.contracts, which this module exposes through `api(...)`.

data class RunContext(
    val runId: String,
    val hostServices: HostServices,
)

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
