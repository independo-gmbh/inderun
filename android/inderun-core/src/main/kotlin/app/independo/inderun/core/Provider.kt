package app.independo.inderun.core

import app.independo.inderun.contracts.ControlApplicationPlan
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.SpeechOutput
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
     * The candidate's control application plan (ADR 025 section 3), verbatim: one entry per speech
     * control the request named, in request order, each `decision: apply` (apply the value through
     * the platform's documented path, before commit) or `decision: omit` (leave the control at its
     * normal behaviour and report it as not applied with the plan's reason). Null when the request
     * names no controls. The engine has checked it against the request before the first attempt. A
     * `required` entry the platform refuses at run time fails the attempt before commit with
     * `CapabilityMismatch` (`details.code: speech_control_unsupported`), which may fall back.
     */
    val controls: List<ControlApplicationPlan>? = null,
    /**
     * Where the provider writes retrievable media for an `artifact` request (ADR 017). The engine
     * holds the bytes; the provider returns the reference [ArtifactWriter.finish] gives it in an
     * `artifact` output. Finishing commits the run. Artifacts this attempt does not return, or that
     * a failed or cancelled attempt wrote, are discarded by the engine. A context built outside an
     * engine writes into a private store whose writers always commit.
     */
    val artifacts: ArtifactSink = ArtifactSink.standalone(),
    /**
     * What [commit] does. The engine supplies it; a context built outside an engine -- a
     * provider's own unit test -- always commits.
     */
    private val commitHandler: () -> Boolean = { true },
    /**
     * What [reportSpeech] does. Mode 1 has no cancel path that reads it, so the engine passes
     * none and a context built elsewhere ignores the call.
     */
    private val reportSpeechHandler: (SpeechOutput) -> Unit = {},
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

    /**
     * Reports what this attempt has settled so far for a speech run: the locale and voice it speaks
     * with and one control record per control it applied or omitted. Call it once the values are
     * known, typically right after [commit]. Only a stream that ends cancelled reads it
     * ([ProviderStreamContext] carries the same call): the cancelled terminal outcome keeps these
     * records and records every other requested control as `not_reported` (ADR 025 section 4). A
     * completed run reports through its output's `speech` instead, so `run()` ignores it. A
     * `text_to_speech` provider should return that section; one that returns none reports no
     * control records, and a run with a required control then fails with `output_mismatch`. A later
     * call replaces an earlier one; a call after the attempt ended or the run was cancelled is
     * ignored.
     */
    fun reportSpeech(speech: SpeechOutput) = reportSpeechHandler(speech)
}

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
