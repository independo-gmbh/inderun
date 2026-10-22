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
    /**
     * What [commit] does. The engine supplies it; a context built outside an engine -- a
     * provider's own unit test -- always commits.
     */
    private val commitHandler: () -> Boolean = { true },
) {
    /**
     * Commits the run to this provider. Call it immediately before the attempt's first
     * externally observable effect -- for managed playback, no later than the first moment
     * sound may reach the user. After commit, a failure ends the run instead of falling back
     * to another provider, because a second provider would repeat what the user may already
     * have heard.
     *
     * Returns `false` when the run can no longer commit (the calling coroutine is no longer
     * active) and when this attempt is over, e.g. a late callback after the engine fell back to
     * another provider; the provider must then not start the effect and should end the attempt.
     * Idempotent: calling it again after a successful commit returns `true`.
     *
     * Providers whose output is only delivered at the end (text from `run()`) need not call it.
     */
    fun commit(): Boolean = commitHandler()
}

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
