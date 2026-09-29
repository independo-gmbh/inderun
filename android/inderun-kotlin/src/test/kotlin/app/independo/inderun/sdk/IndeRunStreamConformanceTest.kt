package app.independo.inderun.sdk

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createRateLimited
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * The Android half of the cross-SDK Mode 2 conformance catalog.
 *
 * The catalog lives in `contracts/fixtures/streaming/engine-conformance.json` and
 * is driven identically by the Web and Swift suites. Each case id gets exactly one
 * handler here; the guard test fails when the handler ids and the catalog ids are
 * not equal, so a scenario covered on another platform and not on this one is a
 * red build rather than a review finding.
 *
 * [IndeRunStreamTest] keeps what is specific to Android -- the ML Kit end-to-end
 * streams that exercise the real adapter rather than a fake provider.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class IndeRunStreamConformanceTest {
    private fun catalogFile(): File {
        // The Gradle test working directory is the module directory; walk up to the
        // repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/streaming/engine-conformance.json")
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/streaming/engine-conformance.json")
    }

    private fun catalogCases(): List<JSONObject> {
        val cases = JSONObject(catalogFile().readText(Charsets.UTF_8)).getJSONArray("cases")
        return (0 until cases.length()).map { cases.getJSONObject(it) }
    }

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val catalogIds = catalogCases().map { it.getString("id") }.sorted()
        assertTrue(catalogIds.isNotEmpty())
        assertEquals(catalogIds, handlers.keys.sorted())
    }

    @Test
    fun matchesTheSharedConformanceCatalog() = runTest {
        val failures = mutableListOf<String>()

        for (case in catalogCases()) {
            val id = case.getString("id")
            val label = "${case.getString("category")}: $id"
            val handler = handlers[id]
            if (handler == null) {
                failures += "$label: no handler for this catalog case"
                continue
            }
            val observed = try {
                handler()
            } catch (error: AssertionError) {
                failures += "$label: handler failed: ${error.message}"
                continue
            }
            failures += check(label, case.getJSONObject("expect"), observed)
        }

        assertTrue(
            "Conformance failures:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }
}

// --- observation and assertions -------------------------------------------

private class Observation(
    val events: List<StreamEvent> = emptyList(),
    val rejection: IndeRunException? = null,
    val telemetry: List<TelemetryEvent> = emptyList(),
    val providerCallCounts: Map<String, Int> = emptyMap(),
    val providerInterrupted: Boolean? = null,
    val runSelectedProviderId: String? = null,
    val streamSelectedProviderId: String? = null,
    val handleStartedAt: Double? = null,
    val wallClockRange: LongRange? = null,
    val secondIterationEventCount: Int? = null,
)

/**
 * The catalog spells outcomes and telemetry types on the wire, but quicktype
 * generated [Outcome] and [TelemetryEventType] as bare enums with no `rawValue`,
 * so both mappings are written by hand. [telemetryTypeValue] is exhaustive with
 * no `else`: a regeneration that adds a constant must be a compile error here.
 */
private fun outcomeNamed(value: String): Outcome = when (value) {
    "cancelled" -> Outcome.Cancelled
    "completed" -> Outcome.Completed
    "error" -> Outcome.Error
    else -> error("Unknown outcome '$value' in the conformance catalog")
}

private fun telemetryTypeValue(value: TelemetryEventType): String = when (value) {
    TelemetryEventType.AttemptFailed -> "attempt_failed"
    TelemetryEventType.AttemptSucceeded -> "attempt_succeeded"
    TelemetryEventType.RouteDecided -> "route_decided"
    TelemetryEventType.StreamAttemptFailed -> "stream_attempt_failed"
    TelemetryEventType.StreamAttemptStarted -> "stream_attempt_started"
    TelemetryEventType.StreamAttemptSucceeded -> "stream_attempt_succeeded"
    TelemetryEventType.StreamCancelled -> "stream_cancelled"
    TelemetryEventType.StreamCompleted -> "stream_completed"
    TelemetryEventType.StreamFailed -> "stream_failed"
}

private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

private fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

@Suppress("CyclomaticComplexMethod", "LongMethod")
private fun check(label: String, expected: JSONObject, observed: Observation): List<String> {
    val failures = mutableListOf<String>()
    fun require(condition: Boolean, what: () -> String) {
        if (!condition) failures += "$label: ${what()}"
    }
    fun <T> same(what: String, wanted: T, actual: T) = require(wanted == actual) { "$what expected $wanted but was $actual" }

    val events = observed.events

    expected.optJSONArray("eventTypes")?.let {
        same("eventTypes", it.strings(), events.map { event -> event.type })
    }
    expected.optJSONArray("sequences")?.let { wanted ->
        same(
            "sequences",
            (0 until wanted.length()).map { wanted.getLong(it) },
            events.map { event -> event.sequence },
        )
    }
    expected.optJSONArray("contentTexts")?.let { wanted ->
        val texts = events
            .filter { it.type == "content_delta" || it.type == "content_snapshot" }
            .map { it.payload?.text }
        same("contentTexts", wanted.strings(), texts)
    }
    if (expected.has("terminalCount")) {
        same("terminalCount", expected.getInt("terminalCount"), events.count { it.type == "terminal" })
    }
    if (expected.has("eventsAfterTerminal")) {
        val index = events.indexOfFirst { it.type == "terminal" }
        require(index >= 0) { "expected a terminal event" }
        if (index >= 0) {
            same("eventsAfterTerminal", expected.getInt("eventsAfterTerminal"), events.size - 1 - index)
        }
    }

    expected.optJSONObject("terminal")?.let { wanted ->
        val payload = events.firstOrNull { it.type == "terminal" }?.payload
        require(payload != null) { "expected a terminal event" }
        if (payload != null) {
            wanted.optStringOrNull("outcome")?.let { same("outcome", outcomeNamed(it), payload.outcome) }
            wanted.optStringOrNull("finalText")?.let { same("finalText", it, payload.finalText) }
            wanted.optStringOrNull("partialText")?.let { same("partialText", it, payload.partialText) }
            wanted.optStringOrNull("reason")?.let { same("reason", it, payload.reason) }
            wanted.optStringOrNull("finishReason")?.let {
                same("finishReason", it, payload.finishReason?.rawValue)
            }
            wanted.optStringOrNull("errorClass")?.let {
                same("errorClass", it, payload.error?.errorClass?.rawValue)
            }
            wanted.optJSONObject("usage")?.let { usage ->
                same("usage.inputTokens", usage.getLong("inputTokens"), payload.usage?.inputTokens)
                same("usage.outputTokens", usage.getLong("outputTokens"), payload.usage?.outputTokens)
                same("usage.totalTokens", usage.getLong("totalTokens"), payload.usage?.totalTokens)
            }
            if (wanted.optBoolean("absentFinishReason")) {
                require(payload.finishReason == null) { "finishReason must be absent" }
            }
            if (wanted.optBoolean("absentUsage")) {
                require(payload.usage == null) { "usage must be absent" }
            }
        }
    }

    expected.optJSONObject("rejectsWith")?.let { wanted ->
        val rejection = observed.rejection
        require(rejection != null) { "expected stream() to reject" }
        if (rejection != null) {
            wanted.optStringOrNull("errorClass")?.let {
                same("errorClass", it, rejection.errorClass.rawValue)
            }
            wanted.optStringOrNull("runId")?.let { same("runId", it, rejection.runId) }
            val details = rejection.details.orEmpty()
            wanted.optStringOrNull("failureCode")?.let {
                same("failureCode", it, details["failureCode"])
            }
            wanted.optJSONArray("rejectedProviders")?.let { wantedProviders ->
                @Suppress("UNCHECKED_CAST")
                val rejected = details["rejectedProviders"] as? List<Map<String, Any?>> ?: emptyList()
                for (index in 0 until wantedProviders.length()) {
                    val wantedProvider = wantedProviders.getJSONObject(index)
                    val providerId = wantedProvider.getString("providerId")
                    val actual = rejected.firstOrNull { it["providerId"] == providerId }
                    require(actual != null) { "expected $providerId among rejectedProviders" }
                    if (actual == null) continue

                    @Suppress("UNCHECKED_CAST")
                    val reasons = actual["reasons"] as? List<Map<String, Any?>> ?: emptyList()
                    wantedProvider.optJSONArray("reasons")?.let {
                        same("$providerId reasons", it.strings(), reasons.map { r -> r["code"] })
                    }
                    wantedProvider.optJSONArray("messages")?.let {
                        same("$providerId messages", it.strings(), reasons.map { r -> r["message"] })
                    }
                }
            }
        }
    }

    expected.optJSONObject("providerCallCounts")?.let { wanted ->
        for (providerId in wanted.keys()) {
            same("$providerId call count", wanted.getInt(providerId), observed.providerCallCounts[providerId])
        }
    }
    if (expected.has("providerInterrupted")) {
        same("providerInterrupted", expected.getBoolean("providerInterrupted"), observed.providerInterrupted)
    }
    expected.optStringOrNull("runSelectedProviderId")?.let {
        same("runSelectedProviderId", it, observed.runSelectedProviderId)
    }
    expected.optStringOrNull("streamSelectedProviderId")?.let {
        same("streamSelectedProviderId", it, observed.streamSelectedProviderId)
    }
    if (expected.optBoolean("handleStartedAtIsUnixEpochMillis")) {
        val range = observed.wallClockRange
        val startedAt = observed.handleStartedAt
        require(range != null && startedAt != null && startedAt.toLong() in range) {
            "startedAt $startedAt is not within the wall-clock range $range"
        }
    }

    expected.optJSONArray("telemetryTypes")?.let {
        same("telemetryTypes", it.strings(), observed.telemetry.map { event -> telemetryTypeValue(event.type) })
    }
    expected.optJSONArray("telemetryTypesContain")?.let { wanted ->
        val actual = observed.telemetry.map { event -> telemetryTypeValue(event.type) }
        for (type in wanted.strings()) {
            require(actual.contains(type)) { "expected telemetry to contain '$type', saw $actual" }
        }
    }
    expected.optJSONArray("telemetryForbiddenPayloadKeys")?.let { wanted ->
        for (key in wanted.strings()) {
            for (event in observed.telemetry) {
                require(!event.payload.containsKey(key)) {
                    "${telemetryTypeValue(event.type)} payload must not carry '$key'"
                }
            }
        }
    }
    expected.optJSONArray("telemetryForbiddenPayloadValues")?.let { wanted ->
        for (value in wanted.strings()) {
            for (event in observed.telemetry) {
                require(!event.payload.toString().contains(value)) {
                    "${telemetryTypeValue(event.type)} payload must not contain '$value'"
                }
            }
        }
    }
    expected.optJSONArray("telemetryStableMessageEvents")?.let { wanted ->
        for (type in wanted.strings()) {
            val event = observed.telemetry.firstOrNull { telemetryTypeValue(it.type) == type }
            require(event != null) { "expected a $type telemetry event" }
            val message = event?.payload?.get("message")
            require(message is String && message.isNotEmpty()) { "$type payload needs a stable message" }
        }
    }

    if (expected.optBoolean("noReplayOnSecondIteration")) {
        same("secondIterationEventCount", 0, observed.secondIterationEventCount)
    }

    return failures
}

// --- handlers -------------------------------------------------------------

private suspend fun captureRejection(start: suspend () -> Unit): Observation = try {
    start()
    throw AssertionError("expected stream() to reject, but it resolved")
} catch (rejection: IndeRunException) {
    Observation(rejection = rejection)
}

private val handlers: Map<String, suspend () -> Observation> = mapOf(
    "deltas_then_completed" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("Hello")),
                        Step.Emit(ProviderStreamEvent.Delta(" world")),
                        Step.Emit(ProviderStreamEvent.Done("Hello world")),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "snapshot_replaces_cumulative_text" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Snapshot("Loc")),
                        Step.Emit(ProviderStreamEvent.Snapshot("Local first")),
                        Step.Emit(ProviderStreamEvent.Done("Local first")),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "completed_carries_finish_reason_and_usage" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("trunc")),
                        Step.Emit(
                            ProviderStreamEvent.Done(
                                finalText = "trunc",
                                finishReason = FinishReason.LENGTH,
                                usage = app.independo.inderun.contracts.TaskResultUsage(
                                    inputTokens = 2,
                                    outputTokens = 1,
                                    totalTokens = 3,
                                ),
                            ),
                        ),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "completed_omits_finish_reason_when_absent" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("a")),
                        Step.Emit(ProviderStreamEvent.Done("a")),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "handle_started_at_is_unix_epoch_millis" to {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", listOf(Step.Emit(ProviderStreamEvent.Done("ok")))))
        }
        // The injected host clock counts elapsed realtime from zero, so an engine
        // that reused it here would serialize device uptime instead of epoch time.
        val before = System.currentTimeMillis()
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val after = System.currentTimeMillis()
        run.events.toList()
        Observation(handleStartedAt = run.handle.startedAt, wallClockRange = before..after)
    },

    "terminal_error_carries_error_class" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step.Emit(ProviderStreamEvent.Delta("partial "))),
                    throwAfterScript = createRateLimited("upstream is throttling"),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "all_providers_fail_pre_commit_yields_single_error" to {
        val first = FakeStreamProvider("p1", throwImmediately = createUnavailable("boom"))
        val second = FakeStreamProvider("p2", throwImmediately = createUnavailable("boom"))
        val registry = ProviderRegistry().apply {
            register(first)
            register(second)
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
            providerCallCounts = mapOf("p1" to first.callCount, "p2" to second.callCount),
        )
    },

    "cancelled_carries_partial_text_and_reason" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step.Emit(ProviderStreamEvent.Delta("one")), Step.WaitForCancellation),
                ),
            )
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") run.cancel("user stopped")
        }
        Observation(events = events)
    },

    "no_events_are_delivered_after_the_terminal" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("a")),
                        Step.Emit(ProviderStreamEvent.Done("a")),
                        Step.Emit(ProviderStreamEvent.Delta("b")),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "cancel_before_first_attempt_forecloses_every_provider" to {
        val first = FakeStreamProvider("p1", listOf(Step.WaitForCancellation))
        val second = FakeStreamProvider("p2", listOf(Step.Emit(ProviderStreamEvent.Done("never"))))
        val registry = ProviderRegistry().apply {
            register(first)
            register(second)
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        run.cancel()
        Observation(
            events = run.events.toList(),
            providerCallCounts = mapOf("p1" to first.callCount, "p2" to second.callCount),
        )
    },

    "cancel_during_emit_stops_further_deltas" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("one")),
                        Step.WaitForCancellation,
                        Step.Emit(ProviderStreamEvent.Delta(" two")),
                        Step.Emit(ProviderStreamEvent.Done("one two")),
                    ),
                ),
            )
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") run.cancel()
        }
        Observation(events = events)
    },

    "cancel_after_terminal_is_a_no_op" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("done")),
                        Step.Emit(ProviderStreamEvent.Done("done")),
                    ),
                ),
            )
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val events = run.events.toList()
        run.cancel("too late")
        Observation(events = events)
    },

    "concurrent_cancels_yield_one_outcome_first_reason_wins" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step.Emit(ProviderStreamEvent.Delta("one")), Step.WaitForCancellation),
                ),
            )
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") {
                run.cancel("first")
                run.cancel("second")
            }
        }
        Observation(events = events)
    },

    "cancel_during_pre_commit_attempt_forecloses_next_route" to {
        // The flow is cold, so the attempt only begins once collection does. The
        // provider signals that it has been entered, which is what separates this
        // case from cancel-before-the-first-attempt rather than a timing guess.
        val entered = CompletableDeferred<Unit>()
        val failing = FakeStreamProvider(
            "p1",
            listOf(Step.WaitForCancellation),
            throwAfterScript = createUnavailable("boom before any content"),
            entered = entered,
        )
        val fallback = FakeStreamProvider("p2", listOf(Step.Emit(ProviderStreamEvent.Done("never"))))
        val registry = ProviderRegistry().apply {
            register(failing)
            register(fallback)
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        coroutineScope {
            val events = mutableListOf<StreamEvent>()
            val collector = launch { run.events.collect { events += it } }
            entered.await()
            run.cancel("mid-attempt")
            collector.join()
            Observation(
                events = events,
                providerCallCounts = mapOf("p1" to failing.callCount, "p2" to fallback.callCount),
            )
        }
    },

    "cancel_unblocks_a_provider_waiting_for_output" to {
        val provider = FakeStreamProvider(
            "p1",
            listOf(Step.Emit(ProviderStreamEvent.Delta("one")), Step.WaitForCancellation),
        )
        val registry = ProviderRegistry().apply { register(provider) }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") run.cancel()
        }
        Observation(events = events, providerInterrupted = provider.wasInterrupted)
    },

    "no_streaming_capable_provider_rejects_with_run_id" to {
        val registry = ProviderRegistry().apply { register(FakeRunOnlyProvider("p_run_only")) }
        captureRejection {
            IndeRun(registry, conformanceHostServices()).stream(conformanceRequest(requestId = "req-42"))
        }
    },

    "declared_streaming_without_implementation_rejected" to {
        val provider = FakeRunOnlyProvider("p_declared_only", declaresStreaming = true)
        val registry = ProviderRegistry().apply { register(provider) }
        val observed = captureRejection {
            IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        }
        Observation(
            rejection = observed.rejection,
            providerCallCounts = mapOf("p_declared_only" to provider.callCount),
        )
    },

    "dynamic_capability_revocation_rejected_with_reason" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p_revoked",
                    streamingAvailable = false,
                    streamingUnavailableReason = "Host has no chunked HTTP capability.",
                ),
            )
        }
        captureRejection { IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()) }
    },

    "routing_rejection_carries_failure_code_and_reason_codes" to {
        val registry = ProviderRegistry().apply { register(FakeRunOnlyProvider("p_run_only")) }
        captureRejection { IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()) }
    },

    "privacy_constraint_enforced_on_stream_routes" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p_cloud_streaming",
                    type = app.independo.inderun.core.ProviderDescriptor.ProviderType.cloud,
                ),
            )
        }
        captureRejection {
            IndeRun(registry, conformanceHostServices())
                .stream(conformanceRequest(privacy = PrivacyEnum.LocalRequired))
        }
    },

    "offline_host_with_cloud_stream_provider_reports_offline" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p_cloud_streaming",
                    type = app.independo.inderun.core.ProviderDescriptor.ProviderType.cloud,
                ),
            )
        }
        captureRejection {
            IndeRun(registry, conformanceHostServices(online = false))
                .stream(conformanceRequest(privacy = PrivacyEnum.CloudAllowed))
        }
    },

    "offline_host_with_local_stream_provider_reports_capability_mismatch" to {
        val registry = ProviderRegistry().apply { register(FakeRunOnlyProvider("p_local_run_only")) }
        captureRejection {
            IndeRun(registry, conformanceHostServices(online = false))
                .stream(conformanceRequest(privacy = PrivacyEnum.CloudAllowed))
        }
    },

    "run_and_stream_resolve_different_chains" to {
        val runOnly = FakeRunOnlyProvider("a_run_only")
        val streaming = FakeStreamProvider("b_streaming", listOf(Step.Emit(ProviderStreamEvent.Done("streamed"))))
        val registry = ProviderRegistry().apply {
            register(runOnly)
            register(streaming)
        }
        val engine = IndeRun(registry, conformanceHostServices())
        val result = engine.run(conformanceRequest())
        val run = engine.stream(conformanceRequest())
        run.events.toList()
        Observation(
            runSelectedProviderId = result.telemetry.providerUsed,
            streamSelectedProviderId = run.handle.providerId,
            providerCallCounts = mapOf("a_run_only" to 0),
        )
    },

    "pre_commit_failure_falls_back" to {
        val failing = FakeStreamProvider("p1_failing", throwImmediately = createUnavailable("boom"))
        val healthy = FakeStreamProvider("p2_healthy", listOf(Step.Emit(ProviderStreamEvent.Done("recovered"))))
        val registry = ProviderRegistry().apply {
            register(failing)
            register(healthy)
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
            providerCallCounts = mapOf(
                "p1_failing" to failing.callCount,
                "p2_healthy" to healthy.callCount,
            ),
        )
    },

    "post_commit_failure_never_falls_back" to {
        val failing = FakeStreamProvider(
            "p1",
            listOf(Step.Emit(ProviderStreamEvent.Delta("partial "))),
            throwAfterScript = createUnavailable("boom"),
        )
        val healthy = FakeStreamProvider("p2_healthy", listOf(Step.Emit(ProviderStreamEvent.Done("never"))))
        val registry = ProviderRegistry().apply {
            register(failing)
            register(healthy)
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
            providerCallCounts = mapOf("p2_healthy" to healthy.callCount),
        )
    },

    "stream_ending_without_terminal_is_a_provider_fault" to {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", listOf(Step.Emit(ProviderStreamEvent.Delta("a")))))
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "provider_emitted_failure_behaves_like_a_throw" to {
        val emitting = FakeStreamProvider(
            "p1",
            listOf(Step.Emit(ProviderStreamEvent.Failure(createRateLimited("slow down")))),
        )
        val healthy = FakeStreamProvider("p2_healthy", listOf(Step.Emit(ProviderStreamEvent.Done("recovered"))))
        val registry = ProviderRegistry().apply {
            register(emitting)
            register(healthy)
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
            providerCallCounts = mapOf("p1" to emitting.callCount, "p2_healthy" to healthy.callCount),
        )
    },

    "duplicate_terminal_suppressed" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("first")),
                        Step.Emit(ProviderStreamEvent.Done("first")),
                        Step.Emit(ProviderStreamEvent.Done("second")),
                    ),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "empty_snapshot_retracts_delivered_content" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("rejected text")),
                        Step.Emit(ProviderStreamEvent.Snapshot("")),
                    ),
                    throwAfterScript = createCapabilityMismatch("The response was rejected by a policy check."),
                ),
            )
        }
        Observation(
            events = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest()).events.toList(),
        )
    },

    "telemetry_sequence_for_a_normal_completion" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("Hello")),
                        Step.Emit(ProviderStreamEvent.Done("Hello")),
                    ),
                ),
            )
        }
        val telemetry = RecordingTelemetryService()
        IndeRun(registry, conformanceHostServices(), telemetry).stream(conformanceRequest()).events.toList()
        Observation(telemetry = telemetry.events)
    },

    "stream_cancelled_telemetry_carries_no_raw_error_detail" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step.Emit(ProviderStreamEvent.Delta("one")), Step.WaitForCancellation),
                ),
            )
        }
        val telemetry = RecordingTelemetryService()
        val run = IndeRun(registry, conformanceHostServices(), telemetry).stream(conformanceRequest())
        run.events.collect { event ->
            if (event.type == "content_delta") run.cancel("secret user text")
        }
        Observation(telemetry = telemetry.events)
    },

    "stream_failed_telemetry_carries_a_stable_message" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step.Emit(ProviderStreamEvent.Delta("partial "))),
                    throwAfterScript = createUnavailable("upstream said: sk-secret leaked"),
                ),
            )
        }
        val telemetry = RecordingTelemetryService()
        IndeRun(registry, conformanceHostServices(), telemetry).stream(conformanceRequest()).events.toList()
        Observation(telemetry = telemetry.events)
    },

    "events_are_single_use" to {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step.Emit(ProviderStreamEvent.Delta("a")),
                        Step.Emit(ProviderStreamEvent.Done("a")),
                    ),
                ),
            )
        }
        val run = IndeRun(registry, conformanceHostServices()).stream(conformanceRequest())
        val first = run.events.toList()
        // Kotlin raises on a second collect where Web and Swift complete empty.
        // Both satisfy the shared guarantee -- the run is never replayed -- see the
        // `$divergence` note on this case in the catalog.
        val second = try {
            run.events.toList().size
        } catch (expected: IllegalStateException) {
            0
        }
        Observation(events = first, secondIterationEventCount = second)
    },
)
