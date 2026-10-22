package app.independo.inderun.sdk

import android.content.Context
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.ModelProfile
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.StreamTerminalOutcomeError
import app.independo.inderun.contracts.StreamTerminalOutcomeTelemetry
import app.independo.inderun.contracts.StreamTerminalOutcomeUsage
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.ArtifactChunk
import app.independo.inderun.core.ArtifactLimits
import app.independo.inderun.core.ArtifactStore
import app.independo.inderun.core.AttemptArtifacts
import app.independo.inderun.core.EventGate
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RouteCandidate
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamCancellationToken
import app.independo.inderun.core.StreamRun
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.TelemetryService
import app.independo.inderun.core.cancelledOutcome
import app.independo.inderun.core.checkOutput
import app.independo.inderun.core.completedOutcome
import app.independo.inderun.core.contentPayload
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.core.errorOutcome
import app.independo.inderun.core.recheckBoundVoice
import app.independo.inderun.core.taskProfileFor
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The primary entry point for the IndeRun Android SDK.
 *
 * Mirrors the TypeScript/Web and Swift engine surface: it is constructed with a
 * [ProviderRegistry], the platform [HostServices], and an optional
 * [TelemetryService]. Use [initialize] for the batteries-included Android setup
 * that builds the default host services and ML Kit provider registry.
 *
 * @param registry Registry filled with active providers.
 * @param hostServices Platform services wrapping OS interfaces (connectivity, secure storage, clock, HTTP).
 * @param telemetry Optional telemetry sink. Falls back to [HostServices.telemetry] when not provided.
 * @param modelProfiles Named model profiles requests can route within (`TaskRequest.modelProfile`).
 *   Defaults to none, so every request routes within the built-in `auto` profile.
 * @param artifactLimits Size limits of the engine's in-memory artifact store (ADR 017). Defaults:
 *   16 MiB per artifact, 64 MiB in total, 1 MiB per [readArtifact] call.
 */
class IndeRun(
    private val registry: ProviderRegistry,
    private val hostServices: HostServices,
    telemetry: TelemetryService? = null,
    private val modelProfiles: ModelProfiles = ModelProfiles(),
    artifactLimits: ArtifactLimits = ArtifactLimits(),
) : IndeRunApi {
    private val router = Router(registry)
    private val artifacts = ArtifactStore(artifactLimits)
    private val telemetryService: TelemetryService? = telemetry ?: hostServices.telemetry

    /**
     * The planner input for the request's model profile; null means `auto`. An unknown name never
     * reaches here: [validateRequest] rejects it first.
     */
    private fun plannerModelProfile(request: TaskRequest): ModelProfile? = (modelProfiles.resolve(request.modelProfile) as? ModelProfiles.Resolution.Profile)?.profile

    /**
     * Orchestrates a [TaskRequest]: validates it, selects a provider chain via
     * routing, executes with deterministic fallback, emits telemetry, and
     * returns the normalized [TaskResult]. An attempt that committed (see
     * [RunContext.commit]) ends the chain: its failure is the run's failure,
     * attributed to that provider.
     *
     * @throws app.independo.inderun.core.IndeRunException on validation, routing, or provider failure.
     */
    override suspend fun run(request: TaskRequest): TaskResult {
        val startTime = hostServices.clock.elapsedRealtimeMillis().toDouble()
        val runId = request.requestId ?: "run_${UUID.randomUUID().toString().take(8).lowercase()}"
        val provenance = ProvenanceRecorder(request.modelProfile)
        // The provider a failed run had committed to, which the failure is attributed to.
        var committedProvider: ProviderAdapter? = null

        try {
            validateRequest(request, runId)
            checkDestination(request, runId)

            val routeSelection = router.selectRoute(
                request,
                hostServices,
                modelProfile = plannerModelProfile(request),
            )
            val providers = listOf(routeSelection.provider) + routeSelection.fallbackProviders
            val attemptedProviderIds = mutableListOf<String>()
            provenance.routed(routeSelection.routePlan)
            val delivery = taskProfileFor(request.task.kind)!!.delivery(request)
            // commit() refuses once the calling coroutine is no longer active.
            val caller = currentCoroutineContext()[Job]

            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.RouteDecided,
                    runId = runId,
                    timestamp = System.currentTimeMillis().toDouble(),
                    payload = mapOf(
                        "selectedProviderId" to routeSelection.routePlan.selectedProviderId,
                        "fallbackProviderIds" to routeSelection.routePlan.fallbackProviderIds,
                        "rejectedProviderIds" to routeSelection.routePlan.rejectedProviders.map { it.providerId },
                        "fallbackAvailable" to (providers.size > 1),
                        "taskKind" to request.task.kind.rawValue,
                        "modelProfile" to (request.modelProfile ?: ModelProfiles.AUTO),
                        "explanation" to routeSelection.explanation,
                    ),
                ),
            )

            // An attempt that committed (see RunContext.commit) ends the chain: its failure is
            // the run's failure.
            for ((index, provider) in providers.withIndex()) {
                val providerId = provider.describe().id
                val voice = routeSelection.candidates.getOrNull(index)?.voice
                attemptedProviderIds += providerId
                // Closed when the attempt ends, so a commit() from a provider callback that fires
                // after the run moved on is refused.
                val latch = CommitLatch()
                val commit = {
                    val (granted, _) = latch.commit { caller?.isActive == false }
                    granted
                }
                val attemptArtifacts = artifacts.attempt(commit)
                // The artifact the application receives; every other one this attempt wrote is
                // released when the attempt ends, however it ends.
                var keptArtifactId: String? = null

                try {
                    // A refusal fails this attempt before it starts, so it falls back like any
                    // other pre-commit provider failure.
                    recheckBoundVoice(request, providerId, voice)?.let { throw it }

                    val result = provider.run(
                        request = request,
                        context = RunContext(
                            runId = runId,
                            hostServices = hostServices,
                            voice = voice,
                            artifacts = attemptArtifacts,
                            commitHandler = commit,
                        ),
                    )
                    val output = deliverToDestination(
                        request,
                        normalizeOutput(request, delivery, result.output, providerId, attemptArtifacts),
                        providerId,
                    )
                    keptArtifactId = engineOwnedArtifactId(output)

                    val totalMs = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime
                    provenance.attempted(providerId, AttemptOutcome.Succeeded, committed = latch.isCommitted)

                    safeEmit(
                        TelemetryEvent(
                            type = TelemetryEventType.AttemptSucceeded,
                            runId = runId,
                            timestamp = System.currentTimeMillis().toDouble(),
                            payload = mapOf(
                                "providerId" to providerId,
                                "durationMs" to totalMs,
                                "fallbackOccurred" to (index > 0),
                                "attemptedProviderIds" to attemptedProviderIds.toList(),
                            ),
                        ),
                    )

                    return result.copy(
                        runId = runId,
                        output = output,
                        telemetry = result.telemetry.copy(
                            providerUsed = providerId,
                            totalMs = totalMs,
                        ),
                        provenance = provenance.build(provider.describe(), result.telemetry.reportedModel),
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    // Closing first settles the commit state: a provider callback racing this
                    // failure either committed before it or is refused.
                    val committed = latch.close()
                    val attemptError = toIndeRunException(
                        error,
                        fallbackRunId = runId,
                        fallbackProviderId = providerId,
                        fallbackDetails = mapOf(
                            "attemptedProviderIds" to attemptedProviderIds.toList(),
                            "fallbackOccurred" to (attemptedProviderIds.size > 1),
                            "routePlan" to routeSelection.routePlan,
                        ),
                    )
                    provenance.attempted(providerId, AttemptOutcome.Failed, attemptError.errorClass, committed)
                    if (committed) {
                        committedProvider = provider
                        throw attemptError
                    }
                    if (index == providers.lastIndex) throw attemptError
                } finally {
                    latch.close()
                    attemptArtifacts.release(keptArtifactId)
                }
            }

            throw createInternal(
                message = "No providers were attempted.",
                runId = runId,
                details = mapOf(
                    "attemptedProviderIds" to attemptedProviderIds,
                ),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val totalMs = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime
            val normalized = toIndeRunException(
                error,
                fallbackRunId = runId,
                fallbackDetails = mapOf(
                    "totalMs" to totalMs,
                ),
            )
            // A routing refusal throws before any attempt; its rejections travel on the details.
            // No attempt produced a result, so the outcome is attributed to no provider -- unless
            // the run had committed to one, which then owns the failure.
            provenance.routingFailed(normalized.details)
            val exception = normalized.withProvenance(provenance.build(committedProvider?.describe()))

            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.AttemptFailed,
                    runId = runId,
                    timestamp = System.currentTimeMillis().toDouble(),
                    payload = mapOf(
                        "providerId" to exception.providerId,
                        "durationMs" to totalMs,
                        "errorClass" to exception.errorClass.rawValue,
                        "message" to getStableMessage(exception.errorClass),
                    ),
                ),
            )

            throw exception
        }
    }

    /**
     * Reports each registered provider's static descriptor and current dynamic capability check,
     * without executing a task. Useful for UI that shows live provider availability before a run.
     */
    override suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> = registry.list().map { provider ->
        val descriptor = provider.describe()
        val capabilities = provider.capabilities(hostServices)
        ProviderCapabilitySnapshot(providerId = descriptor.id, descriptor = descriptor, capabilities = capabilities)
    }

    /**
     * Reads a byte range of an engine-owned media artifact a run produced (ADR 017). Reads are
     * repeatable until the artifact is disposed, and each returns at most
     * [ArtifactLimits.maxReadBytes].
     *
     * @throws app.independo.inderun.core.IndeRunException `Unavailable` (`details.code:
     *   "artifact_not_found"`) for an unknown, disposed or application-owned artifact; `Internal`
     *   with `details.validationIssues` for a malformed request or an offset beyond the end.
     */
    override suspend fun readArtifact(request: ArtifactReadRequest): ArtifactChunk {
        val validationIssues = buildList {
            if (request.artifactId.isEmpty()) {
                add(mapOf("path" to "/artifactId", "message" to "must NOT have fewer than 1 characters"))
            }
            request.offset?.takeIf { it < 0 }?.let { add(mapOf("path" to "/offset", "message" to "must be >= 0")) }
            request.maxBytes?.takeIf { it < 1 }?.let { add(mapOf("path" to "/maxBytes", "message" to "must be >= 1")) }
        }
        if (validationIssues.isNotEmpty()) {
            throw createInternal(
                message = "Validation failed for ArtifactReadRequest: " +
                    validationIssues.joinToString("; ") { "${it["path"]} - ${it["message"]}" },
                details = mapOf("validationIssues" to validationIssues),
            )
        }
        return artifacts.read(request)
    }

    /**
     * Releases the bytes of an engine-owned media artifact. Idempotent: disposing an artifact twice,
     * or one the engine does not hold, does nothing.
     */
    override suspend fun disposeArtifact(artifact: MediaArtifact) {
        if (artifact.owner == ArtifactOwner.Engine) artifacts.dispose(artifact.id)
    }

    /**
     * Checks that an artifact in a provider's output is one this attempt produced, swaps in the
     * reference the store holds, and only then checks the output against the requested delivery:
     * the artifact's media type, size and ownership are the engine's record rather than the
     * provider's claim.
     */
    private fun normalizeOutput(
        request: TaskRequest,
        delivery: OutputDelivery,
        output: TaskOutput?,
        providerId: String,
        attemptArtifacts: AttemptArtifacts,
    ): TaskOutput {
        val resolved = output?.artifact?.let { artifact ->
            val stored = artifacts.reference(artifact.id)
            if (!attemptArtifacts.owns(artifact.id) || stored == null) {
                throw createInternal(
                    message = "Provider '$providerId' returned an artifact it did not hand over in this attempt.",
                    providerId = providerId,
                    details = mapOf("code" to "output_mismatch"),
                )
            }
            output.copy(artifact = stored)
        } ?: output
        checkOutput(request, delivery, resolved, providerId)?.let { throw it }
        return checkNotNull(resolved)
    }

    /**
     * Refuses, before routing, an artifact request whose `destinationRef` this host cannot write
     * to: there is no point running a provider whose result has nowhere to go.
     */
    private suspend fun checkDestination(request: TaskRequest, runId: String) {
        val destinationRef = request.delivery?.destinationRef ?: return
        val destinations = hostServices.artifactDestinations ?: throw createCapabilityMismatch(
            message = "This host has no application artifact destinations.",
            runId = runId,
            details = mapOf("code" to "artifact_destination_unsupported"),
        )
        if (!destinations.accepts(destinationRef, request.delivery?.mediaTypes)) {
            throw createCapabilityMismatch(
                message = "The host refused the requested artifact destination.",
                runId = runId,
                details = mapOf("code" to "artifact_destination_refused"),
            )
        }
    }

    /**
     * Writes a finished artifact to the request's application destination, if it names one, and
     * drops the engine's copy: the result's artifact is then application-owned. The run has
     * committed by now, so a failed write is the run's failure, never a fallback.
     */
    private suspend fun deliverToDestination(request: TaskRequest, output: TaskOutput, providerId: String): TaskOutput {
        val destinationRef = request.delivery?.destinationRef ?: return output
        val artifact = output.artifact ?: return output
        try {
            hostServices.artifactDestinations!!.write(destinationRef, artifact, artifacts.bytes(artifact.id)!!)
        } catch (error: CancellationException) {
            artifacts.dispose(artifact.id)
            throw error
        } catch (_: Throwable) {
            // The host's error stays out of the run's error: it may name the destination.
            artifacts.dispose(artifact.id)
            throw createInternal(
                message = "Writing the artifact to its application destination failed.",
                providerId = providerId,
                details = mapOf("code" to "artifact_destination_write_failed"),
            )
        }
        artifacts.dispose(artifact.id)
        return output.copy(artifact = artifact.copy(owner = ArtifactOwner.Application, destinationRef = destinationRef))
    }

    /**
     * Emits a telemetry event, swallowing any sink failures so telemetry can
     * never disrupt primary execution flows.
     */
    private fun safeEmit(event: TelemetryEvent) {
        val telemetry = telemetryService ?: return
        try {
            telemetry.emit(event)
        } catch (_: Throwable) {
            // Telemetry failures must never disrupt primary execution flows.
        }
    }

    /**
     * Orchestrates a Mode 2 (streaming) execution of a [TaskRequest].
     *
     * The requested interaction mode is a routing input, not a filter applied
     * after routing: the planner rejects providers that cannot stream with their
     * own normalized reason, so a stream and a run over the same registry may
     * legitimately resolve to different provider chains.
     *
     * Two failure surfaces exist, deliberately. Validation and route-selection
     * failures throw from this call, because there is no handle to correlate
     * them with yet. Everything after that — provider failure, cancellation,
     * completion — arrives as the single terminal event in [StreamRun.events].
     *
     * Fallback is narrower than Mode 1's: a provider failure is only
     * fallback-eligible before the run commits to that provider -- its first
     * content event, its explicit [ProviderStreamContext.commit] (managed
     * playback, before the first possible audible effect), or its result
     * handoff, whichever comes first. Once committed, a later failure becomes a
     * terminal error, never a silent provider swap. Cancellation forecloses both
     * at any commit state.
     *
     * The returned flow is cold — the run starts on first collection — and
     * single-use: collecting it twice throws rather than silently re-running the
     * provider.
     *
     * @throws app.independo.inderun.core.IndeRunException on validation or routing failure.
     */
    override suspend fun stream(request: TaskRequest): StreamRun {
        // Two clocks, deliberately: durations must come from the monotonic
        // elapsed-realtime clock, while StreamRunHandle.startedAt is contractually
        // Unix epoch milliseconds and would otherwise serialize device uptime.
        val startElapsedMs = hostServices.clock.elapsedRealtimeMillis().toDouble()
        val startedAtEpochMs = System.currentTimeMillis().toDouble()
        val runId = request.requestId ?: "run_${UUID.randomUUID().toString().take(8).lowercase()}"
        val preRunProvenance = ProvenanceRecorder(request.modelProfile)

        try {
            validateRequest(request, runId)
            checkDestination(request, runId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw toIndeRunException(error, fallbackRunId = runId).withProvenance(preRunProvenance.build())
        }

        val routeSelection = try {
            router.selectRoute(
                request,
                hostServices,
                InteractionMode.Stream,
                plannerModelProfile(request),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val exception = toIndeRunException(error, fallbackRunId = runId)
            preRunProvenance.routingFailed(exception.details)
            throw exception.withProvenance(preRunProvenance.build())
        }
        val providers = listOf(routeSelection.provider) + routeSelection.fallbackProviders

        safeEmit(
            TelemetryEvent(
                type = TelemetryEventType.RouteDecided,
                runId = runId,
                timestamp = System.currentTimeMillis().toDouble(),
                payload = mapOf(
                    "selectedProviderId" to routeSelection.routePlan.selectedProviderId,
                    "fallbackProviderIds" to routeSelection.routePlan.fallbackProviderIds,
                    "rejectedProviderIds" to routeSelection.routePlan.rejectedProviders.map { it.providerId },
                    "fallbackAvailable" to (providers.size > 1),
                    "taskKind" to request.task.kind.rawValue,
                    "modelProfile" to (request.modelProfile ?: ModelProfiles.AUTO),
                    "explanation" to routeSelection.explanation,
                ),
            ),
        )

        // Defensive only: streaming eligibility is decided by the route planner,
        // which throws with its own rejection reasons when nothing can stream.
        // Reaching here means a planned provider was unregistered in between.
        val first = providers.firstOrNull() ?: throw createCapabilityMismatch(
            message = "No eligible provider supports streaming for this request.",
            runId = runId,
            details = mapOf("taskKind" to request.task.kind.rawValue),
        )

        val cancellation = StreamCancellationToken()
        val gate = EventGate(runId)
        val collected = AtomicBoolean(false)

        // channelFlow rather than flow: interrupting a provider that is blocked
        // on a network read means cancelling a child coroutine, and a plain flow
        // builder forbids emitting from a scope it does not own.
        val events = channelFlow {
            check(collected.compareAndSet(false, true)) {
                "StreamRun.events is single-use; collect it once."
            }
            driveStream(
                request = request,
                runId = runId,
                startTime = startElapsedMs,
                candidates = routeSelection.candidates,
                routePlan = routeSelection.routePlan,
                gate = gate,
                cancellation = cancellation,
            )
        }

        return StreamRun(
            handle = StreamRunHandle(
                providerId = first.describe().id,
                runId = runId,
                schemaVersion = SchemaVersion.V1_0,
                startedAt = startedAtEpochMs,
            ),
            events = events,
        ) { reason -> cancellation.cancel(reason) }
    }

    @Suppress("LongMethod", "CyclomaticComplexMethod", "LongParameterList")
    private suspend fun ProducerScope<StreamEvent>.driveStream(
        request: TaskRequest,
        runId: String,
        startTime: Double,
        candidates: List<RouteCandidate>,
        routePlan: RoutePlan,
        gate: EventGate,
        cancellation: StreamCancellationToken,
    ) {
        fun now(): Double = System.currentTimeMillis().toDouble()
        fun elapsed(): Double = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime

        val provenance = ProvenanceRecorder(request.modelProfile).apply { routed(routePlan) }
        val delivery = taskProfileFor(request.task.kind)!!.delivery(request)
        val textRun = delivery == OutputDelivery.Inline

        // `provider` is the one running when cancellation landed, if any, and `committed` whether
        // its attempt had committed; the outcome is attributed to it. `delivered` is an artifact
        // already written to its application destination: those bytes are the application's now,
        // so the outcome reports them.
        suspend fun emitCancelled(
            partialText: String,
            provider: ProviderAdapter?,
            committed: Boolean,
            attempted: List<String>,
            delivered: TaskOutput? = null,
        ) {
            val providerId = provider?.describe()?.id
            providerId?.let { provenance.attempted(it, AttemptOutcome.Cancelled, committed = committed) }
            val terminal = gate.terminate(
                cancelledOutcome(
                    runId = runId,
                    // A text run reports what it delivered; committed playback reports that it
                    // played. An uncommitted non-text run produced nothing to report.
                    partialText = partialText.takeIf { textRun },
                    reason = cancellation.reason,
                    provenance = provenance.build(provider?.describe()),
                    // Committed playback may have been heard.
                    output = delivered ?: if (committed && delivery == OutputDelivery.Playback) {
                        TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput())
                    } else {
                        null
                    },
                ),
                now(),
            )
            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.StreamCancelled,
                    runId = runId,
                    timestamp = now(),
                    payload = buildMap {
                        put("attemptedProviderIds", attempted)
                        providerId?.let { put("providerId", it) }
                    },
                ),
            )
            terminal?.let { send(it) }
        }

        suspend fun emitFailure(
            exception: IndeRunException,
            partialText: String,
            providerId: String?,
            attempted: List<String>,
            outcomeProvenance: ExecutionProvenance,
        ) {
            val contractError = exception.toContractError()
            val terminal = gate.terminate(
                errorOutcome(
                    runId = runId,
                    error = StreamTerminalOutcomeError(
                        details = contractError.details,
                        errorClass = contractError.errorClass,
                        message = contractError.message,
                        provenance = contractError.provenance,
                        providerId = contractError.providerId,
                        retryable = contractError.retryable,
                        retryAfterMs = contractError.retryAfterMs,
                        schemaVersion = contractError.schemaVersion,
                    ),
                    partialText = partialText.takeIf { textRun },
                    provenance = outcomeProvenance,
                ),
                now(),
            )
            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.StreamFailed,
                    runId = runId,
                    timestamp = now(),
                    payload = buildMap {
                        put("errorClass", exception.errorClass.rawValue)
                        put("message", getStableMessage(exception.errorClass))
                        put("attemptedProviderIds", attempted)
                        providerId?.let { put("providerId", it) }
                    },
                ),
            )
            terminal?.let { send(it) }
        }

        val attemptedProviderIds = mutableListOf<String>()

        for ((index, candidate) in candidates.withIndex()) {
            if (cancellation.isCancelled) break

            val provider = candidate.provider
            val providerId = provider.describe().id
            attemptedProviderIds += providerId
            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.StreamAttemptStarted,
                    runId = runId,
                    timestamp = now(),
                    payload = mapOf("providerId" to providerId, "fallbackOccurred" to (index > 0)),
                ),
            )

            // Set once, by whichever comes first in this attempt: the provider's commit(), its
            // first admitted content event, or its result handoff. After it no other provider is
            // tried. Locked because a provider may call commit() from a thread of its own, and
            // closed when the attempt ends, so a commit() arriving after the run moved on is
            // refused rather than committing the attempt that replaced this one.
            val latch = CommitLatch()

            // Emits `stream_attempt_succeeded` exactly once, from whichever commit came first.
            fun markCommitted(refused: () -> Boolean = { false }): Boolean {
                val (granted, first) = latch.commit(refused)
                if (!first) return granted
                safeEmit(
                    TelemetryEvent(
                        type = TelemetryEventType.StreamAttemptSucceeded,
                        runId = runId,
                        timestamp = now(),
                        payload = mapOf(
                            "providerId" to providerId,
                            "attemptedProviderIds" to attemptedProviderIds.toList(),
                        ),
                    ),
                )
                return granted
            }

            val commit = { markCommitted { cancellation.isCancelled || gate.isTerminated } }
            val attemptArtifacts = artifacts.attempt(commit)
            // The artifact the completed terminal carries; every other one this attempt wrote is
            // released when the attempt ends, however it ends.
            var keptArtifactId: String? = null

            var partialText = ""
            var terminated = false
            try {
                // A refusal fails this attempt before it starts, so it falls back like any
                // other pre-commit provider failure.
                recheckBoundVoice(request, providerId, candidate.voice)?.let { throw it }

                val streaming = provider as? StreamingProviderAdapter
                    // Same class of fault as the empty-chain guard: the planner
                    // only routes a stream to providers that implement it.
                    ?: throw createInternal(
                        message = "Provider '$providerId' was routed a stream but does not implement streaming.",
                        runId = runId,
                        providerId = providerId,
                    )

                val context = ProviderStreamContext(
                    runId = runId,
                    hostServices = hostServices,
                    cancellation = cancellation,
                    voice = candidate.voice,
                    artifacts = attemptArtifacts,
                    commitHandler = commit,
                )

                val providerEvents = Channel<ProviderStreamEvent>(Channel.BUFFERED)
                val producer = launch {
                    try {
                        streaming.stream(request, context).collect { providerEvents.send(it) }
                        providerEvents.close()
                    } catch (error: Throwable) {
                        providerEvents.close(error)
                    }
                }
                // Cancelling the producer is what actually ends a read that is
                // already blocked waiting for the next chunk; observing the
                // token between events would leave the caller waiting for the
                // server to speak again before the cancelled outcome arrives.
                cancellation.onCancel { producer.cancel() }

                try {
                    for (event in providerEvents) {
                        if (cancellation.isCancelled) break
                        when (event) {
                            is ProviderStreamEvent.Failure -> throw event.error

                            is ProviderStreamEvent.Delta, is ProviderStreamEvent.Snapshot -> {
                                val text = when (event) {
                                    is ProviderStreamEvent.Delta -> event.text
                                    is ProviderStreamEvent.Snapshot -> event.text
                                    else -> ""
                                }
                                // Content events are text-only (ADR 016 §5).
                                if (!textRun) {
                                    throw checkNotNull(
                                        checkOutput(request, delivery, TaskOutput(type = TaskOutputType.TEXT, text = ""), providerId),
                                    )
                                }
                                partialText = if (event is ProviderStreamEvent.Delta) partialText + text else text
                                markCommitted()
                                val type = if (event is ProviderStreamEvent.Delta) "content_delta" else "content_snapshot"
                                gate.admit(now(), type, contentPayload(text))?.let { send(it) }
                            }

                            // Done (text) or Result (any task): the run's final output.
                            is ProviderStreamEvent.Done, is ProviderStreamEvent.Result -> {
                                val done = event as? ProviderStreamEvent.Done
                                val result = event as? ProviderStreamEvent.Result
                                val normalized = normalizeOutput(
                                    request,
                                    delivery,
                                    result?.output ?: TaskOutput(type = TaskOutputType.TEXT, text = done?.finalText),
                                    providerId,
                                    attemptArtifacts,
                                )
                                markCommitted()
                                // No destination write starts after a cancel. One already running
                                // is not interrupted, but the run still ends cancelled: bytes
                                // already at the destination are the application's, so the outcome
                                // reports them, and anything the engine still holds is released.
                                if (cancellation.isCancelled) break
                                val output = deliverToDestination(request, normalized, providerId)
                                if (cancellation.isCancelled) {
                                    if (output.artifact?.owner != ArtifactOwner.Application) break
                                    emitCancelled(partialText, provider, latch.isCommitted, attemptedProviderIds.toList(), output)
                                    terminated = true
                                    break
                                }
                                keptArtifactId = engineOwnedArtifactId(output)
                                provenance.attempted(providerId, AttemptOutcome.Succeeded, committed = latch.isCommitted)
                                val terminal = gate.terminate(
                                    completedOutcome(
                                        runId = runId,
                                        // A Done carries text only; a Result carries its output,
                                        // and its text too when the output is text.
                                        finalText = done?.finalText ?: output.text.takeIf { output.type == TaskOutputType.TEXT },
                                        finishReason = done?.finishReason ?: result?.finishReason,
                                        usage = done?.usage?.let {
                                            StreamTerminalOutcomeUsage(
                                                inputTokens = it.inputTokens,
                                                outputTokens = it.outputTokens,
                                                totalTokens = it.totalTokens,
                                            )
                                        },
                                        telemetry = StreamTerminalOutcomeTelemetry(
                                            providerUsed = providerId,
                                            totalMs = elapsed(),
                                        ),
                                        provenance = provenance.build(
                                            provider.describe(),
                                            done?.reportedModel ?: result?.reportedModel,
                                        ),
                                        output = output.takeIf { result != null },
                                    ),
                                    now(),
                                )
                                safeEmit(
                                    TelemetryEvent(
                                        type = TelemetryEventType.StreamCompleted,
                                        runId = runId,
                                        timestamp = now(),
                                        payload = mapOf(
                                            "providerId" to providerId,
                                            "durationMs" to elapsed(),
                                            "attemptedProviderIds" to attemptedProviderIds.toList(),
                                        ),
                                    ),
                                )
                                terminated = true
                                terminal?.let { send(it) }
                            }
                        }
                        if (terminated) break
                    }
                } finally {
                    producer.cancel()
                }

                if (terminated) return

                if (cancellation.isCancelled) {
                    attemptArtifacts.release()
                    emitCancelled(partialText, provider, latch.isCommitted, attemptedProviderIds.toList())
                    return
                }

                throw createInternal(
                    message = "Provider '$providerId' stream ended without a terminal event.",
                    runId = runId,
                    providerId = providerId,
                )
            } catch (error: CancellationException) {
                // Cancelling the producer surfaces here as a CancellationException
                // too, so a caller-requested cancel is answered with the terminal
                // outcome it is owed; only cancellation of the collector itself
                // propagates.
                if (cancellation.isCancelled && currentCoroutineContext().isActive) {
                    attemptArtifacts.release()
                    emitCancelled(partialText, provider, latch.isCommitted, attemptedProviderIds.toList())
                    return
                }
                throw error
            } catch (error: Throwable) {
                if (cancellation.isCancelled) {
                    attemptArtifacts.release()
                    emitCancelled(partialText, provider, latch.isCommitted, attemptedProviderIds.toList())
                    return
                }

                val exception = toIndeRunException(
                    error,
                    fallbackRunId = runId,
                    fallbackProviderId = providerId,
                    fallbackDetails = mapOf("attemptedProviderIds" to attemptedProviderIds.toList()),
                )
                // Closing first settles the commit state: a provider callback racing this failure
                // either committed before it or is refused.
                val committed = latch.close()
                provenance.attempted(providerId, AttemptOutcome.Failed, exception.errorClass, committed)

                if (!committed) {
                    safeEmit(
                        TelemetryEvent(
                            type = TelemetryEventType.StreamAttemptFailed,
                            runId = runId,
                            timestamp = now(),
                            payload = mapOf(
                                "providerId" to providerId,
                                "errorClass" to exception.errorClass.rawValue,
                                "message" to getStableMessage(exception.errorClass),
                            ),
                        ),
                    )
                    continue
                }

                // Committed: the failure belongs to this provider, not to the chain.
                attemptArtifacts.release()
                emitFailure(
                    exception,
                    partialText,
                    providerId,
                    attemptedProviderIds.toList(),
                    provenance.build(provider.describe()),
                )
                return
            } finally {
                latch.close()
                attemptArtifacts.release(keptArtifactId)
            }
        }

        // Every provider failed pre-commit, or cancellation landed before any
        // attempt started.
        if (cancellation.isCancelled) {
            emitCancelled("", null, false, attemptedProviderIds.toList())
            return
        }

        emitFailure(
            createUnavailable(
                message = "All eligible streaming providers failed.",
                runId = runId,
                details = mapOf("attemptedProviderIds" to attemptedProviderIds.toList()),
            ),
            partialText = "",
            providerId = null,
            attempted = attemptedProviderIds.toList(),
            outcomeProvenance = provenance.build(),
        )
    }

    /**
     * Returns a stable, generic message for an error class for privacy-preserving telemetry.
     */
    private fun getStableMessage(errorClass: IndeRunErrorClass): String = when (errorClass) {
        IndeRunErrorClass.CapabilityMismatch -> "Provider capability mismatch."
        IndeRunErrorClass.Offline -> "Device is offline."
        IndeRunErrorClass.AuthError -> "Authentication failed."
        IndeRunErrorClass.RateLimited -> "Rate limit exceeded."
        IndeRunErrorClass.Timeout -> "Execution timed out."
        IndeRunErrorClass.Unavailable -> "Provider is unavailable."
        IndeRunErrorClass.Internal -> "An internal engine error occurred."
    }

    private fun validateRequest(request: TaskRequest, runId: String) {
        val validationIssues = mutableListOf<String>()

        if (request.schemaVersion != SchemaVersion.V1_0) {
            validationIssues += "schemaVersion must be '1.0'"
        }
        if (request.requestId != null && request.requestId!!.isBlank()) {
            validationIssues += "requestId must be non-empty when provided."
        }
        if (request.authContextRef != null && request.authContextRef!!.isBlank()) {
            validationIssues += "authContextRef must be non-empty when provided."
        }
        // The per-kind payload rules live in the task profile, the one place the engine
        // branches on the kind.
        val profile = taskProfileFor(request.task.kind)
        if (profile == null) {
            validationIssues += "task kind '${request.task.kind.rawValue}' is not supported by this engine"
        } else {
            validationIssues += profile.validate(request)
        }
        if (modelProfiles.resolve(request.modelProfile) == ModelProfiles.Resolution.Unknown) {
            validationIssues += "modelProfile '${request.modelProfile}' is not a configured model profile."
        }

        if (validationIssues.isNotEmpty()) {
            throw createInternal(
                message = "Validation failed for TaskRequest: ${validationIssues.joinToString("; ")}",
                runId = runId,
                details = mapOf("validationIssues" to validationIssues),
            )
        }
    }

    companion object {
        /**
         * Initializes the IndeRun SDK with the default Android host services and,
         * unless overridden, the default ML Kit provider registry.
         *
         * @param context The application or activity context.
         * @param registry Optional provider registry override.
         * @param modelProfiles Named model profiles requests can route within.
         * @param artifactLimits Size limits of the engine's in-memory artifact store.
         * @return A new [IndeRun] instance.
         */
        @JvmStatic
        @JvmOverloads
        fun initialize(
            context: Context,
            registry: ProviderRegistry? = null,
            modelProfiles: ModelProfiles = ModelProfiles(),
            artifactLimits: ArtifactLimits = ArtifactLimits(),
        ): IndeRun {
            val appContext = context.applicationContext
            val services = HostServicesFactory.create(appContext)
            val providerRegistry = registry ?: AndroidProviderRegistryFactory.makeDefaultRegistry(appContext)
            return IndeRun(providerRegistry, services, modelProfiles = modelProfiles, artifactLimits = artifactLimits)
        }
    }
}

/** The id of an artifact output the engine still holds, which an attempt must keep. */
private fun engineOwnedArtifactId(output: TaskOutput): String? = output.artifact?.takeIf { it.owner == ArtifactOwner.Engine }?.id

/**
 * Records the moment a run committed to one attempt's provider (see [RunContext.commit]).
 * Locked, because a provider may call `commit()` from a thread of its own while the engine reads
 * the state from the coroutine driving the run.
 */
private class CommitLatch {
    private var committed = false
    private var closed = false

    val isCommitted: Boolean
        get() = synchronized(this) { committed }

    /**
     * Commits unless [refused] says the run can no longer commit. The first value is what
     * `commit()` returns to the provider; the second is true only for the call that committed.
     */
    fun commit(refused: () -> Boolean): Pair<Boolean, Boolean> {
        if (refused()) return false to false
        return synchronized(this) {
            when {
                closed -> false to false
                committed -> true to false
                else -> {
                    committed = true
                    true to true
                }
            }
        }
    }

    /**
     * Ends the attempt: every later `commit()` is refused. Returns whether the attempt had
     * committed, read under the same lock, so no commit can land between the two.
     */
    fun close(): Boolean = synchronized(this) {
        closed = true
        committed
    }
}
