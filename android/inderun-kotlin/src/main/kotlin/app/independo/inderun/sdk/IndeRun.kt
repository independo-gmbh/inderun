package app.independo.inderun.sdk

import android.content.Context
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.ModelProfile
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.StreamTerminalOutcomeError
import app.independo.inderun.contracts.StreamTerminalOutcomeTelemetry
import app.independo.inderun.contracts.StreamTerminalOutcomeUsage
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.EventGate
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamCancellationToken
import app.independo.inderun.core.StreamRun
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.TelemetryService
import app.independo.inderun.core.cancelledOutcome
import app.independo.inderun.core.completedOutcome
import app.independo.inderun.core.contentPayload
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.core.errorOutcome
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CancellationException
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
 */
class IndeRun(
    private val registry: ProviderRegistry,
    private val hostServices: HostServices,
    telemetry: TelemetryService? = null,
    private val modelProfiles: ModelProfiles = ModelProfiles(),
) : IndeRunApi {
    private val router = Router(registry)
    private val telemetryService: TelemetryService? = telemetry ?: hostServices.telemetry

    /**
     * The planner input for the request's model profile; null means `auto`. An unknown name never
     * reaches here: [validateRequest] rejects it first.
     */
    private fun plannerModelProfile(request: TaskRequest): ModelProfile? = (modelProfiles.resolve(request.modelProfile) as? ModelProfiles.Resolution.Profile)?.profile

    /**
     * Orchestrates a [TaskRequest]: validates it, selects a provider chain via
     * routing, executes with deterministic fallback, emits telemetry, and
     * returns the normalized [TaskResult].
     *
     * @throws app.independo.inderun.core.IndeRunException on validation, routing, or provider failure.
     */
    override suspend fun run(request: TaskRequest): TaskResult {
        val startTime = hostServices.clock.elapsedRealtimeMillis().toDouble()
        val runId = request.requestId ?: "run_${UUID.randomUUID().toString().take(8).lowercase()}"
        val provenance = ProvenanceRecorder(request.modelProfile)

        try {
            validateRequest(request, runId)

            val routeSelection = router.selectRoute(
                request,
                hostServices,
                modelProfile = plannerModelProfile(request),
            )
            val providers = listOf(routeSelection.provider) + routeSelection.fallbackProviders
            val attemptedProviderIds = mutableListOf<String>()
            provenance.routed(routeSelection.routePlan)

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

            for ((index, provider) in providers.withIndex()) {
                val providerId = provider.describe().id
                attemptedProviderIds += providerId

                try {
                    val result = provider.run(
                        request = request,
                        context = RunContext(runId = runId, hostServices = hostServices),
                    )

                    val totalMs = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime
                    provenance.attempted(providerId, AttemptOutcome.Succeeded)

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
                        telemetry = result.telemetry.copy(
                            providerUsed = providerId,
                            totalMs = totalMs,
                        ),
                        provenance = provenance.build(provider.describe(), result.telemetry.reportedModel),
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
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
                    provenance.attempted(providerId, AttemptOutcome.Failed, attemptError.errorClass)
                    if (index == providers.lastIndex) throw attemptError
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
            // No attempt produced a result, so the outcome is attributed to no provider.
            provenance.routingFailed(normalized.details)
            val exception = normalized.withProvenance(provenance.build())

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
     * fallback-eligible before the first content event has been delivered. Once
     * one has, the run is committed to that provider and a later failure becomes
     * a terminal error, never a silent provider swap. Cancellation forecloses
     * both at any commit state.
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
        } catch (error: IndeRunException) {
            throw error.withProvenance(preRunProvenance.build())
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
                providers = providers,
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
        providers: List<ProviderAdapter>,
        routePlan: RoutePlan,
        gate: EventGate,
        cancellation: StreamCancellationToken,
    ) {
        fun now(): Double = System.currentTimeMillis().toDouble()
        fun elapsed(): Double = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime

        val provenance = ProvenanceRecorder(request.modelProfile).apply { routed(routePlan) }

        // `provider` is the one running when cancellation landed, if any; the outcome is
        // attributed to it.
        suspend fun emitCancelled(partialText: String, provider: ProviderAdapter?, attempted: List<String>) {
            val providerId = provider?.describe()?.id
            providerId?.let { provenance.attempted(it, AttemptOutcome.Cancelled) }
            val terminal = gate.terminate(
                cancelledOutcome(
                    runId = runId,
                    partialText = partialText,
                    reason = cancellation.reason,
                    provenance = provenance.build(provider?.describe()),
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
                    partialText = partialText,
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
        var committed = false

        for ((index, provider) in providers.withIndex()) {
            if (cancellation.isCancelled) break

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

            var partialText = ""
            var terminated = false
            try {
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
                                partialText = if (event is ProviderStreamEvent.Delta) partialText + text else text
                                if (!committed) {
                                    committed = true
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
                                }
                                val type = if (event is ProviderStreamEvent.Delta) "content_delta" else "content_snapshot"
                                gate.admit(now(), type, contentPayload(text))?.let { send(it) }
                            }

                            is ProviderStreamEvent.Done -> {
                                provenance.attempted(providerId, AttemptOutcome.Succeeded)
                                val terminal = gate.terminate(
                                    completedOutcome(
                                        runId = runId,
                                        finalText = event.finalText,
                                        finishReason = event.finishReason,
                                        usage = event.usage?.let {
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
                                        provenance = provenance.build(provider.describe(), event.reportedModel),
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
                    emitCancelled(partialText, provider, attemptedProviderIds.toList())
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
                    emitCancelled(partialText, provider, attemptedProviderIds.toList())
                    return
                }
                throw error
            } catch (error: Throwable) {
                if (cancellation.isCancelled) {
                    emitCancelled(partialText, provider, attemptedProviderIds.toList())
                    return
                }

                val exception = toIndeRunException(
                    error,
                    fallbackRunId = runId,
                    fallbackProviderId = providerId,
                    fallbackDetails = mapOf("attemptedProviderIds" to attemptedProviderIds.toList()),
                )
                provenance.attempted(providerId, AttemptOutcome.Failed, exception.errorClass)

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
                emitFailure(
                    exception,
                    partialText,
                    providerId,
                    attemptedProviderIds.toList(),
                    provenance.build(provider.describe()),
                )
                return
            }
        }

        // Every provider failed pre-commit, or cancellation landed before any
        // attempt started.
        if (cancellation.isCancelled) {
            emitCancelled("", null, attemptedProviderIds.toList())
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
        if (request.task.kind != TaskKind.TEXT_TO_TEXT) {
            validationIssues += "task.kind must be 'text_to_text'"
        }

        val hasPrompt = !request.prompt.isNullOrBlank()
        val hasMessages = !request.messages.isNullOrEmpty()

        if (request.requestId != null && request.requestId!!.isBlank()) {
            validationIssues += "requestId must be non-empty when provided."
        }
        if (request.prompt != null && request.prompt!!.isBlank()) {
            validationIssues += "prompt must be non-empty when provided."
        }
        if (request.authContextRef != null && request.authContextRef!!.isBlank()) {
            validationIssues += "authContextRef must be non-empty when provided."
        }
        if (request.messages?.any { it.content.isBlank() } == true) {
            validationIssues += "messages[].content must be non-empty."
        }
        if (!hasPrompt && !hasMessages) {
            validationIssues += "Either prompt or messages must be provided and non-empty."
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
         * @return A new [IndeRun] instance.
         */
        @JvmStatic
        @JvmOverloads
        fun initialize(
            context: Context,
            registry: ProviderRegistry? = null,
            modelProfiles: ModelProfiles = ModelProfiles(),
        ): IndeRun {
            val appContext = context.applicationContext
            val services = HostServicesFactory.create(appContext)
            val providerRegistry = registry ?: AndroidProviderRegistryFactory.makeDefaultRegistry(appContext)
            return IndeRun(providerRegistry, services, modelProfiles = modelProfiles)
        }
    }
}
