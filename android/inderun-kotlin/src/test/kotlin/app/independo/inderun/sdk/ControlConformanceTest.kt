package app.independo.inderun.sdk

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.ControlApplicationPlan
import app.independo.inderun.contracts.ControlDecision
import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.ControlOmissionReason
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.PlaybackControls
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderPrivacy
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskAvailability
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.RequestedNumber
import app.independo.inderun.contracts.RequestedUnitNumber
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.RoutePlannerInput
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SharedSynthesisControls
import app.independo.inderun.contracts.SpeechControlDeclaration
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlLifetime
import app.independo.inderun.contracts.SpeechControlMethod
import app.independo.inderun.contracts.SpeechControlOutcome
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlPhase
import app.independo.inderun.contracts.SpeechControlRange
import app.independo.inderun.contracts.SpeechControlState
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.contracts.SpeechControlValueKind
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechOutput
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.ControlOutcomeEnding
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.completeControlOutcomes
import app.independo.inderun.core.completeOutputControls
import app.independo.inderun.core.controlMethodFor
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.lang.reflect.Proxy

/**
 * The Android half of the three ADR 025 scenario catalogs in `contracts/fixtures/execution/`:
 * `control-plan-integrity.json` (a plan inconsistent with the request stops the run before any
 * attempt), `control-outcomes.json` (the engine validates and completes the provider's control
 * records) and `control-execution.json` (plans reach the attempt; commit, fallback and
 * cancellation keep their guarantees). One handler per case id each; the guard tests fail when the
 * handler ids and the catalog ids differ. Mirrors `controls.conformance.test.ts` and
 * `ControlConformanceTests.swift`.
 *
 * Every wait is bounded, so a regression fails instead of hanging. Robolectric is required because
 * `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class ControlConformanceTest {
    // --- catalogs ----------------------------------------------------------------------------

    private fun catalogCases(name: String): List<JSONObject> {
        // The Gradle test working directory is the module directory; walk up to the repository
        // root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/execution/$name")
            if (candidate.isFile) {
                val cases = JSONObject(candidate.readText(Charsets.UTF_8)).getJSONArray("cases")
                return (0 until cases.length()).map { cases.getJSONObject(it) }
            }
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/execution/$name")
    }

    private fun catalogIds(name: String): List<String> = catalogCases(name).map { it.getString("id") }.sorted()

    private fun case(name: String, id: String): JSONObject = catalogCases(name).first { it.getString("id") == id }

    // --- control-plan-integrity.json ---------------------------------------------------------

    private val planIntegrityHandlers: Map<String, suspend TestScope.(JSONObject) -> Unit> = listOf(
        "consistent_plan",
        "no_controls_no_plan",
        "required_plan_missing",
        "required_plan_empty",
        "required_plan_omitted",
        "plan_value_differs",
        "plan_requirement_differs",
        "preferred_plan_missing",
        "plan_for_unrequested_control",
        "plan_without_request",
        "duplicate_plan_entry",
        "fallback_candidate_inconsistent",
        "omit_without_reason",
        "apply_with_reason",
    ).associateWith { { entry: JSONObject -> runPlanIntegrityCase(entry) } }

    private suspend fun TestScope.runPlanIntegrityCase(entry: JSONObject) {
        val request = parseRequest(entry.getJSONObject("request"))
        val primaryPlan = parsePlan(entry.opt("candidateControls"))
        val candidates = mutableListOf("tts" to primaryPlan)
        if (entry.has("fallbackCandidateControls")) {
            candidates += "tts_fallback" to parsePlan(entry.opt("fallbackCandidateControls"))
        }
        val expected = entry.getJSONObject("expected")
        for (mode in Mode.entries) {
            val fakes = listOf(
                ControlFake("tts", emptyList(), listOf(Step.Commit, Step.Finish)),
                ControlFake("tts_fallback", emptyList(), listOf(Step.Commit, Step.Finish)),
            )
            val label = "${entry.getString("id")} $mode"
            val engine = engine(fakes, planner = candidates)
            val observation = observeRun(engine, request, mode)
            if (expected.optBoolean("refused", true).not()) {
                assertEquals(label, "completed", observation.outcome)
                assertEquals(label, 1, fakes[0].receivedControls.size)
                assertEquals(label, primaryPlan?.map(::planMap), fakes[0].receivedControls[0]?.map(::planMap))
                continue
            }
            assertEquals(label, "failed", observation.outcome)
            assertEquals(label, expected.getString("errorClass"), observation.errorClass)
            assertEquals(label, expected.getString("detailsCode"), observation.errorCode)
            assertEquals(label, expected.getLong("attemptCount"), observation.provenance?.attemptCount)
            assertEquals(label, listOf(0, 0), fakes.map { it.callCount })
        }
    }

    @Test
    fun implementsEveryPlanIntegrityCaseAndNoOthers() {
        val ids = catalogIds("control-plan-integrity.json")
        assertTrue(ids.isNotEmpty())
        assertEquals(ids, planIntegrityHandlers.keys.sorted())
    }

    @Test
    fun matchesTheSharedPlanIntegrityCatalog() = runTest {
        for (entry in catalogCases("control-plan-integrity.json")) {
            val handler = planIntegrityHandlers[entry.getString("id")] ?: fail("no handler for '${entry.getString("id")}'").let { return@runTest }
            handler(entry)
        }
    }

    /**
     * The plan selects a provider but lists no candidate for it. The router then attempts a
     * candidate it synthesizes without a plan, so the plan check has to cover what is attempted,
     * not only what the plan lists.
     */
    @Test
    fun aSynthesizedCandidateWithoutAPlanIsRefusedBeforeAnyAttempt() = runTest {
        val request = parseRequest(case("control-plan-integrity.json", "required_plan_missing").getJSONObject("request"))
        for (mode in Mode.entries) {
            val fake = ControlFake("tts", emptyList(), listOf(Step.Commit, Step.Finish))
            val observation = observeRun(engine(listOf(fake), planner = emptyList(), selected = "tts"), request, mode)

            assertEquals("$mode", "failed", observation.outcome)
            assertEquals("$mode", "Internal", observation.errorClass)
            assertEquals("$mode", "control_plan_mismatch", observation.errorCode)
            assertEquals("$mode", 0L, observation.provenance?.attemptCount)
            assertEquals("$mode", 0, fake.callCount)
        }
    }

    // --- control-outcomes.json ---------------------------------------------------------------

    private val allControls = listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch, SpeechControlId.PlaybackVolume)

    private val outcomeHandlers: Map<String, suspend TestScope.(JSONObject) -> Unit> =
        listOf(
            "complete_records",
            "preferred_record_missing",
            "required_record_missing",
            "required_not_applied",
            "duplicate_record",
            "unrequested_record",
            "requested_value_differs",
            "volume_reported_as_synthesis",
        ).associateWith<String, suspend TestScope.(JSONObject) -> Unit> { { entry -> runCompletedOutcomeCase(entry) } } +
            ("cancelled_keeps_known_records" to { entry: JSONObject -> runCancelledOutcomeCase(entry) }) +
            listOf("preferred_only_no_speech_section", "required_no_speech_section")
                .associateWith<String, suspend TestScope.(JSONObject) -> Unit> { { entry -> runNoSpeechSectionCase(entry) } }

    /** A completed run (both modes) whose provider reports the case's records in its output. */
    private suspend fun TestScope.runCompletedOutcomeCase(entry: JSONObject) {
        val request = parseRequest(entry.getJSONObject("request"))
        val reported = parseOutcomes(entry.getJSONArray("reported"))
        val expected = entry.getJSONObject("expected")
        for (mode in Mode.entries) {
            val label = "${entry.getString("id")} $mode"
            val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.FinishWith(reported)))
            val observation = observeRun(engine(listOf(fake)), request, mode)
            // The helper the engine calls gives the same answer on its own.
            val direct = runCatching { completeControlOutcomes(request, reported, ControlOutcomeEnding.Completed, "tts") }
            if (expected.optBoolean("failed")) {
                assertEquals(label, "failed", observation.outcome)
                assertEquals(label, expected.getString("errorClass"), observation.errorClass)
                assertEquals(label, expected.getString("detailsCode"), observation.errorCode)
                val error = direct.exceptionOrNull() as? IndeRunException ?: fail("$label: helper accepted the records").let { return }
                assertEquals(label, IndeRunErrorClass.Internal, error.errorClass)
            } else {
                assertEquals(label, "completed", observation.outcome)
                val controls = canonical(expected.getJSONArray("controls"))
                assertEquals(label, controls, canonical(observation.output?.speech?.controls?.map(::outcomeMap)))
                assertEquals(label, controls, canonical(direct.getOrThrow().map(::outcomeMap)))
            }
            // Nothing is replayed after a failure that followed the commit.
            assertEquals(label, 1, fake.callCount)
        }
    }

    /** A completed run (both modes) whose provider's output has no speech section at all. */
    private suspend fun TestScope.runNoSpeechSectionCase(entry: JSONObject) {
        val request = parseRequest(entry.getJSONObject("request"))
        assertTrue(entry.isNull("reported"))
        val expected = entry.getJSONObject("expected")
        val bare = TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput())
        for (mode in Mode.entries) {
            val label = "${entry.getString("id")} $mode"
            val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.FinishWithoutSpeech))
            val observation = observeRun(engine(listOf(fake)), request, mode)
            val direct = runCatching { completeOutputControls(request, bare, "tts") }
            if (expected.optBoolean("failed")) {
                assertEquals(label, "failed", observation.outcome)
                assertEquals(label, expected.getString("errorClass"), observation.errorClass)
                assertEquals(label, expected.getString("detailsCode"), observation.errorCode)
                val error = direct.exceptionOrNull() as? IndeRunException ?: fail("$label: helper accepted the output").let { return }
                assertEquals(label, IndeRunErrorClass.Internal, error.errorClass)
            } else {
                // Passed unchanged: no section is invented, so there are no records either.
                assertTrue(label, !expected.has("controls"))
                assertEquals(label, "completed", observation.outcome)
                assertNull(label, observation.output?.speech)
                assertNull(label, direct.getOrThrow().speech)
            }
            assertEquals(label, 1, fake.callCount)
        }
    }

    /** A cancelled stream whose provider reported the case's records before the stop. */
    private suspend fun TestScope.runCancelledOutcomeCase(entry: JSONObject) {
        val request = parseRequest(entry.getJSONObject("request"))
        val reported = parseOutcomes(entry.getJSONArray("reported"))
        val expected = entry.getJSONObject("expected")
        val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.Report(reported), Step.WaitForCancellation))
        val observation = observeRun(engine(listOf(fake)), request, Mode.Stream, cancelWhen = fake.waiting)
        assertEquals(false, expected.optBoolean("failed"))
        assertEquals("cancelled", observation.outcome)
        val controls = canonical(expected.getJSONArray("controls"))
        assertEquals(controls, canonical(observation.output?.speech?.controls?.map(::outcomeMap)))
        val direct = completeControlOutcomes(request, reported, ControlOutcomeEnding.Cancelled, "tts")
        assertEquals(controls, canonical(direct.map(::outcomeMap)))
    }

    @Test
    fun implementsEveryOutcomeCaseAndNoOthers() {
        val ids = catalogIds("control-outcomes.json")
        assertTrue(ids.isNotEmpty())
        assertEquals(ids, outcomeHandlers.keys.sorted())
    }

    @Test
    fun matchesTheSharedOutcomeCatalog() = runTest {
        for (entry in catalogCases("control-outcomes.json")) {
            val handler = outcomeHandlers[entry.getString("id")] ?: fail("no handler for '${entry.getString("id")}'").let { return@runTest }
            handler(entry)
        }
    }

    // --- control-execution.json --------------------------------------------------------------

    private val executionHandlers: Map<String, suspend TestScope.(JSONObject) -> Unit> = listOf(
        "precommit_control_refusal_falls_back_once",
        "postcommit_failure_is_not_replayed",
        "cancel_before_commit_runs_nothing",
        "cancel_after_commit_keeps_known_records",
        "late_callback_after_cancel_is_suppressed",
        "plan_reaches_provider",
    ).associateWith { { entry: JSONObject -> runExecutionCase(entry) } }

    private suspend fun TestScope.runExecutionCase(entry: JSONObject) {
        val request = parseRequest(entry.getJSONObject("request"))
        val expected = entry.getJSONObject("expect")
        val modes = entry.getJSONArray("modes").let { modes -> List(modes.length()) { Mode.of(modes.getString(it)) } }
        for (mode in modes) {
            val label = "${entry.getString("id")} $mode"
            val providers = entry.getJSONArray("providers")
            val fakes = List(providers.length()) { index ->
                val provider = providers.getJSONObject(index)
                ControlFake(
                    id = provider.getString("id"),
                    controls = provider.optJSONArray("controls")?.let { c -> List(c.length()) { SpeechControlId.fromRawValue(c.getString(it))!! } }.orEmpty(),
                    script = provider.getJSONArray("script").let { s -> List(s.length()) { Step.named(s.getString(it)) } },
                )
            }
            fun fake(id: String) = fakes.first { it.id == id }
            val cancelWhen = if (entry.optString("cancelWhen") == "waiting") fakes.first { it.waitsForCancellation }.waiting else null
            val observation = observeRun(engine(fakes), request, mode, cancelWhen)
            // The stream may end as soon as the cancel lands: let every fake finish its script first.
            for (entered in fakes.filter { it.callCount > 0 }) {
                withTimeout(WAIT_MS) { entered.done.await() }
            }
            val provenance = observation.provenance ?: fail("$label: no provenance").let { return }

            assertEquals(label, expected.getString("outcome"), observation.outcome)
            expected.optString("errorClass").takeIf { it.isNotEmpty() }?.let { assertEquals(label, it, observation.errorClass) }
            expected.optJSONObject("providerCallCounts")?.let { counts ->
                counts.keys().forEach { id -> assertEquals("$label $id calls", counts.getInt(id), fake(id).callCount) }
            }
            expected.optJSONObject("receivedControls")?.let { received ->
                received.keys().forEach { id ->
                    assertEquals("$label $id controls", 1, fake(id).receivedControls.size)
                    assertEquals(
                        "$label $id controls",
                        canonical(received.getJSONArray(id)),
                        canonical(fake(id).receivedControls[0]?.map(::planMap)),
                    )
                }
            }
            expected.optJSONArray("attempts")?.let { attempts ->
                val wanted = List(attempts.length()) { attempts.getJSONArray(it).let { pair -> listOf(pair.getString(0), pair.getString(1)) } }
                assertEquals(label, wanted, provenance.attempts.map { listOf(it.providerId, it.outcome.rawValue) })
            }
            expected.optJSONObject("attemptErrorClasses")?.let { classes ->
                classes.keys().forEach { id ->
                    assertEquals(label, classes.getString(id), provenance.attempts.first { it.providerId == id }.errorClass?.rawValue)
                }
            }
            expected.optJSONArray("committedAttempts")?.let { committed ->
                assertEquals(
                    label,
                    List(committed.length()) { committed.getString(it) },
                    provenance.attempts.filter { it.committed == true }.map { it.providerId },
                )
            }
            if (expected.has("fallbackOccurred")) {
                assertEquals(label, expected.getBoolean("fallbackOccurred"), provenance.fallbackOccurred)
            }
            expected.optJSONObject("commitResults")?.let { results ->
                results.keys().forEach { id ->
                    val wanted = results.getJSONArray(id).let { r -> List(r.length()) { r.getBoolean(it) } }
                    assertEquals("$label $id commits", wanted, fake(id).commitResults)
                }
            }
            if (expected.has("output")) {
                val output = observation.output ?: fail("$label: no output").let { return }
                assertEquals(label, canonical(expected.getJSONObject("output")), canonical(outputMap(output)))
            }
            if (expected.optBoolean("absentOutput")) assertNull(label, observation.output)
            if (mode == Mode.Stream && expected.has("eventTypes")) {
                val types = expected.getJSONArray("eventTypes")
                assertEquals(label, List(types.length()) { types.getString(it) }, observation.eventTypes)
            }
        }
    }

    @Test
    fun implementsEveryExecutionCaseAndNoOthers() {
        val ids = catalogIds("control-execution.json")
        assertTrue(ids.isNotEmpty())
        assertEquals(ids, executionHandlers.keys.sorted())
    }

    @Test
    fun matchesTheSharedExecutionCatalog() = runTest {
        for (entry in catalogCases("control-execution.json")) {
            val handler = executionHandlers[entry.getString("id")] ?: fail("no handler for '${entry.getString("id")}'").let { return@runTest }
            handler(entry)
        }
    }

    // --- beyond the catalogs -----------------------------------------------------------------

    private fun executionRequest(id: String) = parseRequest(case("control-execution.json", id).getJSONObject("request"))

    private fun outcomeRequest(id: String) = parseRequest(case("control-outcomes.json", id).getJSONObject("request"))

    private val plainRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_1,
        task = TaskRequestTask(TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(text = "Guten Morgen!", locale = "de-AT"),
        delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
    )

    /**
     * A required control no provider supports is a routing rejection: it reaches the error's
     * details and the provenance, and no attempt is made (ADR 025 section 2).
     */
    @Test
    fun failsCapabilityMismatchWhenNoProviderSupportsARequiredControl() = runTest {
        val request = executionRequest("postcommit_failure_is_not_replayed")
        for (mode in Mode.entries) {
            val fake = ControlFake("tts", emptyList(), listOf(Step.Commit, Step.Finish))
            val observation = observeRun(engine(listOf(fake)), request, mode)
            assertEquals("$mode", "failed", observation.outcome)
            assertEquals("$mode", "CapabilityMismatch", observation.errorClass)
            val provenance = observation.provenance!!
            assertEquals("$mode", 0L, provenance.attemptCount)
            assertEquals("$mode", listOf("tts"), provenance.routeRejections.map { it.providerId })
            assertTrue("$mode", provenance.routeRejections.first().codes.contains(Code.SpeechControlUnsupported))
            assertEquals("$mode", 0, fake.callCount)
        }
    }

    @Test
    fun routeRejectionCodeReachesTheErrorDetails() = runTest {
        val request = executionRequest("postcommit_failure_is_not_replayed")
        val fake = ControlFake("tts", emptyList(), listOf(Step.Commit, Step.Finish))
        val error = runCatching { engine(listOf(fake)).run(request) }.exceptionOrNull() as? IndeRunException
            ?: fail("expected a routing failure").let { return@runTest }
        val rejected = error.details!!["rejectedProviders"] as List<*>
        val first = rejected.first() as Map<*, *>
        assertEquals("tts", first["providerId"])
        val reasons = first["reasons"] as List<*>
        assertTrue(reasons.any { (it as Map<*, *>)["code"] == "speech_control_unsupported" })
    }

    @Test
    fun leavesARequestWithoutControlsExactlyAsBefore() = runTest {
        val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.Finish))
        val observation = observeRun(engine(listOf(fake)), plainRequest, Mode.Run)
        assertEquals(1, fake.receivedControls.size)
        assertNull(fake.receivedControls.first())
        val output = observation.output!!
        assertEquals(
            mapOf("type" to "playback", "playback" to emptyMap<String, Any>(), "speech" to mapOf("locale" to "de-AT")),
            canonical(outputMap(output)),
        )
    }

    @Test
    fun refusesRecordsOnARequestWithoutControls() = runTest {
        val records = listOf(
            SpeechControlOutcome(
                effective = 1.0,
                id = SpeechControlId.SpeechPitch,
                method = SpeechControlMethod.PlatformSynthesis,
                requested = 1.0,
                status = SpeechControlStatus.Applied,
            ),
        )
        val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.FinishWith(records)))
        val observation = observeRun(engine(listOf(fake)), plainRequest, Mode.Run)
        assertEquals("failed", observation.outcome)
        assertEquals("output_mismatch", observation.errorCode)
    }

    @Test
    fun refusesACompletedOutputWithoutASpeechSectionWhenTheRequestHasControls() {
        val request = outcomeRequest("preferred_record_missing")
        val output = TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput())
        val error = runCatching { completeOutputControls(request, output, "tts") }.exceptionOrNull() as? IndeRunException
            ?: fail("expected a refusal").let { return }
        assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        assertEquals("output_mismatch", error.details?.get("code"))
    }

    @Test
    fun refusesAnAppliedRecordWithoutAMethodAndANotAppliedRecordWithoutAReason() {
        val request = outcomeRequest("preferred_record_missing")
        val noMethod = SpeechControlOutcome(
            effective = 0.85,
            id = SpeechControlId.SpeechSpeakingRate,
            requested = 0.85,
            status = SpeechControlStatus.Applied,
        )
        val noReason = SpeechControlOutcome(
            id = SpeechControlId.SpeechPitch,
            requested = 1.05,
            status = SpeechControlStatus.NotApplied,
        )
        for (record in listOf(noMethod, noReason)) {
            val refused = runCatching { completeControlOutcomes(request, listOf(record), ControlOutcomeEnding.Cancelled, "tts") }
            assertTrue("${record.id}", refused.exceptionOrNull() is IndeRunException)
        }
    }

    /**
     * An output_mismatch on control records before the attempt committed is a provider fault that
     * may fall back, like every other output check.
     */
    @Test
    fun fallsBackFromAnUncommittedAttemptWhoseControlRecordsBreakTheRules() = runTest {
        val request = outcomeRequest("preferred_record_missing")
        val broken = listOf(brokenRecord())
        for (mode in Mode.entries) {
            val a = ControlFake("a_primary", allControls, listOf(Step.FinishWith(broken)))
            val b = ControlFake("b_secondary", allControls, listOf(Step.Commit, Step.Finish))
            val observation = observeRun(engine(listOf(a, b)), request, mode)
            assertEquals("$mode", "completed", observation.outcome)
            assertEquals(
                "$mode",
                listOf(listOf("a_primary", "failed"), listOf("b_secondary", "succeeded")),
                observation.provenance!!.attempts.map { listOf(it.providerId, it.outcome.rawValue) },
            )
        }
    }

    @Test
    fun dropsAReportThatBreaksTheRecordRulesFromACancelledTerminal() = runTest {
        val request = outcomeRequest("cancelled_keeps_known_records")
        val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.Report(listOf(brokenRecord())), Step.WaitForCancellation))
        val observation = observeRun(engine(listOf(fake)), request, Mode.Stream, cancelWhen = fake.waiting)
        assertEquals("cancelled", observation.outcome)
        val controls = observation.output!!.speech!!.controls!!
        assertEquals(allControls, controls.map { it.id })
        assertEquals(List(3) { SpeechControlStatus.NotApplied }, controls.map { it.status })
        assertEquals(List(3) { SpeechControlOutcomeReason.NotReported }, controls.map { it.reason })
    }

    @Test
    fun aCancelledRunWhoseProviderNeverReportedCarriesNoSpeechSection() = runTest {
        val request = outcomeRequest("cancelled_keeps_known_records")
        val fake = ControlFake("tts", allControls, listOf(Step.Commit, Step.WaitForCancellation))
        val observation = observeRun(engine(listOf(fake)), request, Mode.Stream, cancelWhen = fake.waiting)
        assertEquals("cancelled", observation.outcome)
        assertNull(observation.output?.speech)
    }

    @Test
    fun reportSpeechIsANoOpByDefault() {
        val context = RunContext(runId = "r", hostServices = host)
        assertNull(context.controls)
        context.reportSpeech(SpeechOutput(locale = "de-AT"))
        val streamContext = ProviderStreamContext(
            runId = "r",
            hostServices = host,
            cancellation = app.independo.inderun.core.StreamCancellationToken(),
        )
        assertNull(streamContext.controls)
        streamContext.reportSpeech(SpeechOutput(locale = "de-AT"))
    }

    /** An applied rate that claims playback attenuation: a rule-breaking record. */
    private fun brokenRecord() = SpeechControlOutcome(
        effective = 0.85,
        id = SpeechControlId.SpeechSpeakingRate,
        method = SpeechControlMethod.PlaybackAttenuation,
        requested = 0.85,
        status = SpeechControlStatus.Applied,
    )

    // --- running a case ----------------------------------------------------------------------

    private enum class Mode {
        Run,
        Stream,
        ;

        companion object {
            fun of(raw: String) = if (raw == "run") Run else Stream
        }
    }

    private data class Observation(
        /** `completed`, `failed` or `cancelled`. */
        val outcome: String,
        val output: TaskOutput? = null,
        val errorClass: String? = null,
        val errorCode: String? = null,
        val provenance: ExecutionProvenance? = null,
        val eventTypes: List<String> = emptyList(),
    )

    private val host = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis(): Long = 0L
        },
    )

    /**
     * An engine over [fakes]. With [planner], routing returns exactly those candidates (provider id
     * and plan, a null plan being an absent key) instead of the shared planner's plan.
     */
    private fun engine(
        fakes: List<ControlFake>,
        planner: List<Pair<String, List<ControlApplicationPlan>?>>? = null,
        selected: String? = planner?.firstOrNull()?.first,
    ): IndeRun {
        val registry = ProviderRegistry().apply { fakes.forEach { register(it) } }
        val engine = IndeRun(registry, host)
        if (planner != null) injectPlanner(engine, registry, planner, selected)
        return engine
    }

    /**
     * Replaces the engine's router with one planning through [candidates]. The route planner is
     * internal to `inderun-core` (there is no second planner to swap in), so the test reaches it by
     * reflection, as `TaskCapabilityRoutingTest` does.
     */
    private fun injectPlanner(
        engine: IndeRun,
        registry: ProviderRegistry,
        candidates: List<Pair<String, List<ControlApplicationPlan>?>>,
        selected: String?,
    ) {
        val plannerType = Class.forName("app.independo.inderun.core.RoutePlanner")
        val ids = candidates.map { it.first }
        val planner = Proxy.newProxyInstance(plannerType.classLoader, arrayOf(plannerType)) { proxy, method, args ->
            when (method.name) {
                "planRoute" -> {
                    @Suppress("UNUSED_VARIABLE")
                    val input = args!![0] as RoutePlannerInput
                    RoutePlan(
                        candidates = candidates.mapIndexed { index, (providerId, controls) ->
                            Candidate(controls = controls, order = index.toLong(), providerId = providerId)
                        },
                        explanation = Explanation(selectedProviderId = selected, summary = "injected"),
                        fallbackProviderIds = ids.drop(1),
                        rejectedProviders = emptyList(),
                        selectedProviderId = selected,
                    )
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args!![0]
                else -> "InjectedRoutePlanner"
            }
        }
        val router = Router::class.java
            .getDeclaredConstructor(ProviderRegistry::class.java, plannerType)
            .apply { isAccessible = true }
            .newInstance(registry, planner)
        IndeRun::class.java.getDeclaredField("router").apply { isAccessible = true }.set(engine, router)
    }

    private fun failure(error: Throwable): Observation {
        val exception = error as? IndeRunException ?: throw AssertionError("expected an IndeRunException, got $error", error)
        return Observation(
            outcome = "failed",
            errorClass = exception.errorClass.rawValue,
            errorCode = exception.details?.get("code") as? String,
            provenance = exception.provenance,
        )
    }

    /**
     * Runs [request] in [mode]. A stream is drained to its terminal; with [cancelWhen], it is
     * cancelled once that signal fires. Every wait is bounded.
     */
    private suspend fun TestScope.observeRun(
        engine: IndeRun,
        request: TaskRequest,
        mode: Mode,
        cancelWhen: CompletableDeferred<Unit>? = null,
    ): Observation {
        when (mode) {
            Mode.Run -> {
                val result = try {
                    withTimeout(WAIT_MS) { engine.run(request) }
                } catch (error: IndeRunException) {
                    return failure(error)
                }
                return Observation(outcome = "completed", output = result.output, provenance = result.provenance)
            }
            Mode.Stream -> {
                val run = try {
                    withTimeout(WAIT_MS) { engine.stream(request) }
                } catch (error: IndeRunException) {
                    return failure(error)
                }
                val draining = async { run.events.toList() }
                if (cancelWhen != null) {
                    withTimeout(WAIT_MS) { cancelWhen.await() }
                    run.cancel()
                }
                val events = withTimeout(WAIT_MS) { draining.await() }
                val last = events.last()
                assertEquals("terminal", last.type)
                val terminal = last.payload!!
                return Observation(
                    outcome = if (terminal.outcome == Outcome.Error) "failed" else terminal.outcome!!.rawValue,
                    output = terminal.output,
                    errorClass = terminal.error?.errorClass?.rawValue,
                    errorCode = terminal.error?.details?.get("code") as? String,
                    provenance = terminal.provenance ?: terminal.error?.provenance,
                    eventTypes = events.map { it.type },
                )
            }
        }
    }

    // --- JSON in and out ---------------------------------------------------------------------

    /** There is no generated JSON decoder for the Kotlin contracts; this reads the fields the catalogs use. */
    private fun parseRequest(json: JSONObject): TaskRequest {
        val speech = json.getJSONObject("speech")
        val delivery = json.getJSONObject("delivery")
        fun requirement(from: JSONObject) = if (from.has("requirement")) RequirementLevel.fromRawValue(from.getString("requirement")) else null
        return TaskRequest(
            schemaVersion = SchemaVersion.fromRawValue(json.getString("schemaVersion"))!!,
            task = TaskRequestTask(TaskKind.fromRawValue(json.getJSONObject("task").getString("kind"))!!),
            speech = SpeechInput(
                text = speech.getString("text"),
                locale = speech.getString("locale"),
                controls = speech.optJSONObject("controls")?.let { controls ->
                    SharedSynthesisControls(
                        speakingRate = controls.optJSONObject("speakingRate")?.let { RequestedNumber(value = it.getDouble("value"), requirement = requirement(it)) },
                        pitch = controls.optJSONObject("pitch")?.let { RequestedNumber(value = it.getDouble("value"), requirement = requirement(it)) },
                    )
                },
            ),
            delivery = OutputDeliveryRequest(
                mode = OutputDelivery.fromRawValue(delivery.getString("mode"))!!,
                playback = delivery.optJSONObject("playback")?.let { playback ->
                    PlaybackControls(
                        volume = playback.optJSONObject("volume")?.let { RequestedUnitNumber(value = it.getDouble("value"), requirement = requirement(it)) },
                    )
                },
            ),
        )
    }

    /** A plan array, or null for an absent or null key. */
    private fun parsePlan(value: Any?): List<ControlApplicationPlan>? {
        val array = value as? JSONArray ?: return null
        return List(array.length()) { index ->
            val entry = array.getJSONObject(index)
            ControlApplicationPlan(
                decision = ControlDecision.fromRawValue(entry.getString("decision"))!!,
                id = SpeechControlId.fromRawValue(entry.getString("id"))!!,
                reason = if (entry.has("reason")) ControlOmissionReason.fromRawValue(entry.getString("reason")) else null,
                requirement = RequirementLevel.fromRawValue(entry.getString("requirement"))!!,
                value = entry.getDouble("value"),
            )
        }
    }

    private fun parseOutcomes(array: JSONArray): List<SpeechControlOutcome> = List(array.length()) { index ->
        val entry = array.getJSONObject(index)
        SpeechControlOutcome(
            effective = if (entry.has("effective")) entry.getDouble("effective") else null,
            id = SpeechControlId.fromRawValue(entry.getString("id"))!!,
            method = if (entry.has("method")) SpeechControlMethod.fromRawValue(entry.getString("method")) else null,
            reason = if (entry.has("reason")) SpeechControlOutcomeReason.fromRawValue(entry.getString("reason")) else null,
            requested = entry.getDouble("requested"),
            status = SpeechControlStatus.fromRawValue(entry.getString("status"))!!,
        )
    }

    private fun planMap(plan: ControlApplicationPlan): Map<String, Any> = buildMap {
        put("decision", plan.decision.rawValue)
        put("id", plan.id.rawValue)
        plan.reason?.let { put("reason", it.rawValue) }
        put("requirement", plan.requirement.rawValue)
        put("value", plan.value)
    }

    private fun outcomeMap(outcome: SpeechControlOutcome): Map<String, Any> = buildMap {
        outcome.effective?.let { put("effective", it) }
        put("id", outcome.id.rawValue)
        outcome.method?.let { put("method", it.rawValue) }
        outcome.reason?.let { put("reason", it.rawValue) }
        put("requested", outcome.requested)
        put("status", outcome.status.rawValue)
    }

    private fun outputMap(output: TaskOutput): Map<String, Any> = buildMap {
        put("type", output.type.rawValue)
        output.playback?.let { put("playback", emptyMap<String, Any>()) }
        output.speech?.let { speech ->
            put(
                "speech",
                buildMap<String, Any> {
                    put("locale", speech.locale)
                    speech.controls?.let { put("controls", it.map(::outcomeMap)) }
                },
            )
        }
    }

    /** Sorted structures with every number as a Double, since org.json may parse a whole number as an Integer. */
    private fun canonical(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().associateWith { canonical(value.get(it)) }
        is JSONArray -> List(value.length()) { canonical(value.get(it)) }
        is Map<*, *> -> value.entries.sortedBy { it.key as String }.associate { it.key as String to canonical(it.value) }
        is List<*> -> value.map(::canonical)
        is Number -> value.toDouble()
        else -> value
    }

    // --- the fake ----------------------------------------------------------------------------

    private sealed interface Step {
        data object RefuseControl : Step
        data object Commit : Step
        data object ReportApplied : Step
        data object Finish : Step
        data object Fail : Step
        data object WaitForCancellation : Step

        /** Reports exactly these records (control-outcomes cases). */
        data class Report(val records: List<SpeechControlOutcome>) : Step

        /** Finishes with exactly these records (control-outcomes cases). */
        data class FinishWith(val records: List<SpeechControlOutcome>) : Step

        /** Finishes with an output that has no speech section (control-outcomes cases). */
        data object FinishWithoutSpeech : Step

        companion object {
            fun named(name: String): Step = when (name) {
                "refuse_control" -> RefuseControl
                "commit" -> Commit
                "report_applied" -> ReportApplied
                "finish" -> Finish
                "fail" -> Fail
                "wait_for_cancellation" -> WaitForCancellation
                else -> error("unknown script step '$name'")
            }
        }
    }

    private val controlRanges = mapOf(
        SpeechControlId.SpeechSpeakingRate to (0.5 to 2.0),
        SpeechControlId.SpeechPitch to (0.5 to 2.0),
        SpeechControlId.PlaybackVolume to (0.0 to 1.0),
    )

    /** The record a fake reports for one plan entry: applied as planned, or omitted with its reason. */
    private fun recordFor(entry: ControlApplicationPlan): SpeechControlOutcome = when (entry.decision) {
        ControlDecision.Apply -> SpeechControlOutcome(
            effective = entry.value,
            id = entry.id,
            method = controlMethodFor(entry.id),
            requested = entry.value,
            status = SpeechControlStatus.Applied,
        )
        ControlDecision.Omit -> SpeechControlOutcome(
            id = entry.id,
            reason = entry.reason?.let { SpeechControlOutcomeReason.fromRawValue(it.rawValue) },
            requested = entry.value,
            status = SpeechControlStatus.NotApplied,
        )
    }

    /**
     * A speech provider in the catalogs' vocabulary (see the `$comment` and `$scriptSteps` of
     * `control-execution.json`): it declares the given playback controls with task-level states,
     * lists no voices, and runs its script, recording what it was handed and what `commit()`
     * returned.
     */
    private inner class ControlFake(
        val id: String,
        private val controls: List<SpeechControlId>,
        private val script: List<Step>,
    ) : StreamingProviderAdapter {
        private val lock = Any()
        private var calls = 0
        private val received = mutableListOf<List<ControlApplicationPlan>?>()
        private val commits = mutableListOf<Boolean>()

        /** Completes once the fake has reached `wait_for_cancellation`. */
        val waiting = CompletableDeferred<Unit>()

        /** Completes when the fake's script has ended, for however long after the run itself ended. */
        val done = CompletableDeferred<Unit>()

        val callCount: Int get() = synchronized(lock) { calls }
        val receivedControls: List<List<ControlApplicationPlan>?> get() = synchronized(lock) { received.toList() }
        val commitResults: List<Boolean> get() = synchronized(lock) { commits.toList() }
        val waitsForCancellation: Boolean get() = script.contains(Step.WaitForCancellation)

        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = id,
            type = ProviderType.Local,
            transport = ProviderTransport.InProcess,
            supports = ProviderSupports(
                run = true,
                streaming = true,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = CancelSemantics.Soft,
            tasks = listOf("text_to_speech"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_speech",
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(run = true, stream = true),
                    cancel = CancelSemantics.Soft,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                    locales = listOf("de-AT"),
                    controls = controls.takeIf { it.isNotEmpty() }?.map {
                        SpeechControlDeclaration(
                            deliveries = listOf(ControlDelivery.Playback),
                            id = it,
                            lifetime = SpeechControlLifetime.Utterance,
                            phase = if (it == SpeechControlId.PlaybackVolume) SpeechControlPhase.Playback else SpeechControlPhase.Synthesis,
                            valueKind = SpeechControlValueKind.Number,
                        )
                    },
                ),
            ),
            privacy = ProviderPrivacy(dataLeavesDevice = false),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(
                ProviderTaskAvailability(
                    kind = "text_to_speech",
                    controlStates = controls.takeIf { it.isNotEmpty() }?.map {
                        val (min, max) = controlRanges.getValue(it)
                        SpeechControlState(
                            available = true,
                            delivery = ControlDelivery.Playback,
                            id = it,
                            range = SpeechControlRange(max = max, min = min),
                        )
                    },
                ),
            ),
        )

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            val output = play(context.controls, context::commit, context::reportSpeech, cancellation = null)
                ?: throw IllegalStateException("$id ended its run without a result")
            return TaskResult(
                finishReason = FinishReason.STOP,
                output = output,
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_1,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
            )
        }

        override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
            val output = play(context.controls, context::commit, context::reportSpeech, context.cancellation)
            if (output != null) emit(ProviderStreamEvent.Result(output, finishReason = FinishReason.STOP))
        }

        private suspend fun play(
            plan: List<ControlApplicationPlan>?,
            commit: () -> Boolean,
            report: (SpeechOutput) -> Unit,
            cancellation: app.independo.inderun.core.StreamCancellationToken?,
        ): TaskOutput? {
            try {
                synchronized(lock) {
                    calls += 1
                    received += plan
                }
                val entries = plan.orEmpty()
                fun finished(records: List<SpeechControlOutcome>?) = TaskOutput(
                    type = TaskOutputType.PLAYBACK,
                    playback = PlaybackOutput(),
                    speech = SpeechOutput(controls = records, locale = "de-AT"),
                )
                for (step in script) {
                    when (step) {
                        is Step.Report -> report(SpeechOutput(controls = step.records, locale = "de-AT"))
                        is Step.FinishWith -> return finished(step.records)
                        Step.FinishWithoutSpeech -> return TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput())
                        Step.RefuseControl -> throw createCapabilityMismatch(
                            message = "The platform refused a required speech control.",
                            providerId = id,
                            details = mapOf("code" to "speech_control_unsupported"),
                        )
                        Step.Commit -> {
                            val granted = commit()
                            synchronized(lock) { commits += granted }
                        }
                        Step.ReportApplied -> report(
                            SpeechOutput(controls = entries.filter { it.decision == ControlDecision.Apply }.map(::recordFor), locale = "de-AT"),
                        )
                        Step.Finish -> return finished(if (plan == null) null else entries.map(::recordFor))
                        Step.Fail -> throw createUnavailable(message = "The fake failed.", providerId = id, retryable = false)
                        Step.WaitForCancellation -> {
                            waiting.complete(Unit)
                            if (cancellation != null) {
                                val cancelled = CompletableDeferred<Unit>()
                                cancellation.onCancel { cancelled.complete(Unit) }
                                // The later steps run as late callbacks, so the wait itself must
                                // not be cut short by the engine cancelling this coroutine.
                                withContext(NonCancellable) { cancelled.await() }
                            }
                        }
                    }
                }
                return null
            } finally {
                done.complete(Unit)
            }
        }
    }

    private companion object {
        /** Upper bound for every wait, so a regression fails instead of hanging. */
        const val WAIT_MS = 5_000L
    }
}
