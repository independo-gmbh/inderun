package app.independo.inderun.sdk

import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.LocaleRequirement
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.PreparationItem
import app.independo.inderun.contracts.PreparationStatus
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamTerminalOutcome
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.VoiceRequirement
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.Router
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

/** How long a first run waits for preparation when its request sets no `timeoutMs`. */
private const val DEFAULT_FIRST_RUN_PREPARE_MS = 30_000L

private val READY = setOf(PreparationStatus.Prepared, PreparationStatus.AlreadyReady)

/** How one provider's preparation ended, shared with callers that waited for it. */
private data class PreparationOutcome(val status: PreparationStatus, val reason: String? = null)

/**
 * What a preparation covered. A voice or locale is a scope of its own: having prepared `de-DE`
 * says nothing about the voice a run for `en-US` needs.
 */
private fun scope(kind: String, locale: String?, voiceId: String?) = "$kind|${locale.orEmpty()}|${voiceId.orEmpty()}"

/** One step of a preparation: progress on an item, or an item's result. */
internal sealed interface PreparationStep {
    data class Progress(val providerId: String, val task: String, val fractionCompleted: Double?) : PreparationStep

    data class Finished(val item: PreparationItem) : PreparationStep
}

/**
 * The engine's half of ADR 019: what is prepared, and how a preparation runs. Lives apart from
 * [IndeRun] because a preparation shares none of a run's fallback or commit rules.
 */
internal class Preparer(
    private val registry: ProviderRegistry,
    private val router: Router,
    private val hostServices: HostServices,
) {
    private val preparedScopes = ConcurrentHashMap.newKeySet<String>()
    private val firstRuns = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val running = ConcurrentHashMap<String, CompletableDeferred<PreparationOutcome>>()

    /**
     * The task kinds a registered provider declares it can prepare, within [tasks] when given.
     * Asks no provider anything, so a request with nothing to prepare costs nothing.
     */
    fun preparableKinds(tasks: List<String>?): List<String> = registry.list()
        .flatMap { it.describe().taskCapabilities.orEmpty() }
        .filter { it.interaction.prepare == true }
        .map { it.kind }
        .distinct()
        .filter { tasks == null || it in tasks }

    /** Remembers what is really ready: a skipped or failed item must get its next chance. */
    fun markPrepared(kinds: List<String>, request: PrepareRequest, items: List<PreparationItem>) {
        kinds
            .filter { kind -> items.filter { it.task == kind }.all { it.status in READY } }
            .forEach { kind -> preparedScopes.add(scope(kind, request.locale, request.voice?.id)) }
    }

    /**
     * Prepares what [request] needs before its first run, once per task kind: it waits for what is
     * loading and starts a download only under `autoDownload`. A `cold` item is left alone, because
     * a cold run warms itself and warming first would be slower. Bounded, and never a failure: when
     * this ends, normal routing decides, with its own fallback and refusals.
     */
    suspend fun beforeFirstRun(request: TaskRequest, runId: String) {
        val kind = request.task.kind.rawValue
        val speech = request.speech
        val key = scope(kind, speech?.locale, speech?.voice?.id)
        if (key in preparedScopes || preparableKinds(listOf(kind)).isEmpty()) return

        val mine = CompletableDeferred<Unit>()
        val earlier = firstRuns.putIfAbsent(key, mine)
        if (earlier != null) {
            earlier.await()
            return
        }
        try {
            val scope = PrepareRequest(
                locale = speech?.locale,
                localeMatch = speech?.localeMatch,
                privacy = request.constraints?.privacy,
                tasks = listOf(kind),
                voice = speech?.voice?.let {
                    app.independo.inderun.contracts.PrepareVoice(gender = it.gender, id = it.id, providerId = it.providerId)
                },
            )
            val bound = request.constraints?.timeoutMs ?: DEFAULT_FIRST_RUN_PREPARE_MS
            try {
                withTimeoutOrNull(bound) { steps(scope, runId, firstRun = true).collect {} }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // Routing reports what is wrong, with a provider-specific reason.
            }
            // Once per scope, whatever came of it: routing answers from here on.
            preparedScopes.add(key)
        } finally {
            firstRuns.remove(key)
            mine.complete(Unit)
        }
    }

    /** Prepares each provider and task in scope, emitting progress and then one item for each. */
    fun steps(request: PrepareRequest, runId: String, firstRun: Boolean): Flow<PreparationStep> = flow {
        for (task in preparableKinds(request.tasks)) {
            for (candidate in router.planPreparation(plannerTask(task, request), request.privacy, hostServices)) {
                val providerId = candidate.provider.describe().id
                val voiceId = candidate.voice?.id
                fun item(status: PreparationStatus, reason: String? = null) = PreparationStep.Finished(
                    PreparationItem(providerId = providerId, reason = reason, status = status, task = task, voiceId = voiceId),
                )

                if (candidate.readiness == ProviderReadiness.Ready || (firstRun && candidate.readiness == ProviderReadiness.Cold)) {
                    emit(item(PreparationStatus.AlreadyReady))
                    continue
                }
                val allowed = request.allowDownload ?: registry.allowsAutoDownload(providerId)
                if (candidate.readiness == ProviderReadiness.NotPrepared && !allowed) {
                    emit(item(PreparationStatus.Skipped, "A download is needed, and neither autoDownload nor allowDownload permits it."))
                    continue
                }

                val key = "$providerId|$task|${voiceId.orEmpty()}"
                val started = CompletableDeferred<PreparationOutcome>()
                val earlier = running.putIfAbsent(key, started)
                if (earlier != null) {
                    val shared = earlier.await()
                    emit(item(shared.status, shared.reason))
                    continue
                }
                var outcome = PreparationOutcome(PreparationStatus.Failed, "The preparation was stopped.")
                try {
                    val context = ProviderPrepareContext(runId, hostServices, task, request.locale, candidate.voice)
                    candidate.provider.prepare(context).collect { progress ->
                        emit(PreparationStep.Progress(providerId, task, progress.fractionCompleted))
                    }
                    outcome = PreparationOutcome(PreparationStatus.Prepared)
                    emit(item(outcome.status))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    val reason = toIndeRunException(error, fallbackRunId = runId, fallbackProviderId = providerId).message
                    outcome = PreparationOutcome(PreparationStatus.Failed, reason)
                    emit(item(outcome.status, outcome.reason))
                } finally {
                    running.remove(key)
                    started.complete(outcome)
                }
            }
        }
    }

    private fun plannerTask(kind: String, request: PrepareRequest) = RoutePlannerInputTask(
        kind = kind,
        inputs = listOf(TaskInputKind.Text),
        locale = request.locale?.let { LocaleRequirement(tag = it, match = request.localeMatch ?: LocaleMatch.Language) },
        voice = request.voice?.let {
            VoiceRequirement(gender = it.gender, id = it.id, providerId = it.providerId, requirement = RequirementLevel.Preferred)
        },
    )
}

/**
 * How a [prepare] run ended. One failed item does not fail the run.
 *
 * @property cancelled `true` when the run was stopped.
 */
data class PreparationResult(
    val cancelled: Boolean,
    val items: List<PreparationItem>,
    val runId: String,
    val outcome: StreamTerminalOutcome,
)

/** What [prepare] returns: a handle on a preparation in progress. */
class Preparation internal constructor(
    val runId: String,
    /** Completes when done or stopped. Fails only when the run itself fails. */
    val result: Deferred<PreparationResult>,
    private val onCancel: (String?) -> Unit,
) {
    /** Stops waiting; idempotent. A platform download already started may go on. */
    fun cancel(reason: String? = null) = onCancel(reason)
}

/**
 * Makes registered providers ready ahead of a run. Optional, for applications that want the first
 * call to be fast or want to show progress: without it, the first run of a task waits for what is
 * loading by itself. A download starts only where `autoDownload` at registration or
 * [PrepareRequest.allowDownload] permits it. See ADR 019.
 *
 * @param onProgress Called as an item advances, with the provider, the task, and a fraction from 0
 *   to 1 when the platform has one.
 * @throws IndeRunException exactly as [IndeRunApi.prepare] does.
 */
suspend fun IndeRunApi.prepare(
    scope: CoroutineScope,
    request: PrepareRequest = PrepareRequest(),
    onProgress: ((providerId: String, task: String, fractionCompleted: Double?) -> Unit)? = null,
): Preparation {
    val run = prepare(request)
    val runId = run.handle.runId
    val result = CompletableDeferred<PreparationResult>()
    scope.launch {
        try {
            var terminal: StreamEvent? = null
            run.events.collect { event ->
                if (event.type == "preparation_progress") {
                    val payload = event.payload
                    onProgress?.invoke(payload?.providerId.orEmpty(), payload?.task.orEmpty(), payload?.fractionCompleted)
                }
                if (event.type == "terminal") terminal = event
            }
            val payload = terminal?.payload
                ?: throw createInternal("Run $runId ended without a terminal event.", runId = runId)
            if (payload.outcome == Outcome.Error) {
                throw createInternal(payload.error?.message ?: "Preparation failed.", runId = runId)
            }
            result.complete(
                PreparationResult(
                    cancelled = payload.outcome == Outcome.Cancelled,
                    items = payload.output?.preparation.orEmpty(),
                    runId = runId,
                    outcome = StreamTerminalOutcome(
                        outcome = payload.outcome ?: Outcome.Completed,
                        runId = runId,
                        schemaVersion = app.independo.inderun.contracts.SchemaVersion.V1_0,
                    ),
                ),
            )
        } catch (cancelled: CancellationException) {
            result.completeExceptionally(cancelled)
            throw cancelled
        } catch (error: Throwable) {
            result.completeExceptionally(error)
        }
    }
    return Preparation(runId, result) { reason -> run.cancel(reason) }
}
