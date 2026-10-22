package app.independo.inderun.sdk

import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.Privacy
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
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.RoutePlannerInput
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.lang.reflect.Proxy

/**
 * Per-task provider capabilities through the real Rust planner (#243). The planner semantics are
 * pinned by the shared vectors in `contracts/fixtures/routing/`; these tests check that the Kotlin
 * engine hands the planner the per-task declarations and surfaces them, and that each attempt is
 * handed the voice the plan bound for its provider, re-checked against the privacy policy (#245).
 */
@RunWith(RobolectricTestRunner::class)
class TaskCapabilityRoutingTest {
    private val hostServices = HostServices(
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

    private val textRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Hello",
        task = TaskRequestTask(),
    )

    private val speechRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(text = "Hallo", locale = "de-AT", voice = SpeechVoice(gender = VoiceGender.Female)),
        delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
        constraints = TaskRequestConstraints(privacy = Privacy.LocalRequired),
    )

    @Test
    fun textRequestIsNeverRoutedToASpeechOnlyProvider() = runTest {
        val registry = ProviderRegistry().apply {
            register(SpeechOnlyProvider())
            register(TextProvider())
        }

        val result = IndeRun(registry, hostServices).run(textRequest)

        assertEquals("z_text", result.telemetry.providerUsed)
        val rejection = result.provenance!!.routeRejections.single { it.providerId == "a_speech_only" }
        assertEquals(listOf(Code.TaskNotSupported), rejection.codes)
    }

    @Test
    fun textRequestSendsTextInputSoAnImageOnlyProviderIsRejected() = runTest {
        val registry = ProviderRegistry().apply {
            register(ImageOnlyTextProvider())
            register(TextProvider())
        }

        val result = IndeRun(registry, hostServices).run(textRequest)

        assertEquals("z_text", result.telemetry.providerUsed)
        val rejection = result.provenance!!.routeRejections.single { it.providerId == "a_image_only" }
        assertEquals(listOf(Code.InputNotSupported), rejection.codes)
    }

    @Test
    fun textRequestFailsWithTaskNotSupportedWhenOnlySpeechIsRegistered() = runTest {
        val registry = ProviderRegistry().apply { register(SpeechOnlyProvider()) }

        val error = runCatching { IndeRun(registry, hostServices).run(textRequest) }.exceptionOrNull()
            as? IndeRunException ?: return@runTest fail("Expected a routing refusal")

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals(listOf(Code.TaskNotSupported), error.provenance!!.routeRejections.single().codes)
    }

    @Test
    fun checkCapabilitiesReportsTaskCapabilities() = runTest {
        val registry = ProviderRegistry().apply { register(SpeechOnlyProvider()) }

        val snapshot = IndeRun(registry, hostServices).checkCapabilities().single()

        val capability = snapshot.descriptor.taskCapabilities!!.single()
        assertEquals("text_to_speech", capability.kind)
        assertEquals(OutputDelivery.Playback, capability.outputs.single().delivery)
        assertEquals("de-DE", snapshot.capabilities.taskCapabilities!!.single().voices!!.single().locale)
    }

    @Test
    fun boundVoiceReachesTheRunContext() = runTest {
        val contexts = mutableListOf<RunContext>()
        val registry = ProviderRegistry().apply {
            register(
                ListedVoiceSpeechProvider(
                    id = "local_speech",
                    voices = listOf(
                        ProviderVoice(locale = "de-DE", gender = VoiceGender.Male),
                        ProviderVoice(locale = "de-AT", gender = VoiceGender.Female),
                    ),
                    contexts = contexts,
                ),
            )
        }

        IndeRun(registry, hostServices).run(speechRequest)

        assertEquals(listOf(ProviderVoice(locale = "de-AT", gender = VoiceGender.Female)), contexts.map { it.voice })
    }

    @Test
    fun recheckRefusesANetworkVoiceUnderLocalRequiredAndFallsBack() = runTest {
        val contexts = mutableListOf<RunContext>()
        val registry = ProviderRegistry().apply {
            register(
                ListedVoiceSpeechProvider(
                    id = "a_bound_to_network",
                    voices = listOf(ProviderVoice(locale = "de-AT", networkRequired = true)),
                    contexts = contexts,
                ),
            )
            register(ListedVoiceSpeechProvider(id = "b_local", voices = listOf(ProviderVoice(locale = "de-AT")), contexts = contexts))
        }
        val engine = IndeRun(registry, hostServices)
        // The shared planner never binds a network voice under local_required, so a plan that
        // does is injected to exercise the engine's own pre-attempt check.
        injectPlanner(engine, registry) { input ->
            RoutePlan(
                candidates = input.providers.mapIndexed { index, provider ->
                    Candidate(
                        order = index.toLong(),
                        providerId = provider.descriptor.id,
                        voice = provider.capabilities.taskCapabilities!!.first().voices!!.first(),
                    )
                },
                explanation = Explanation(selectedProviderId = "a_bound_to_network", summary = "injected"),
                fallbackProviderIds = listOf("b_local"),
                rejectedProviders = emptyList(),
                selectedProviderId = "a_bound_to_network",
            )
        }

        val result = engine.run(speechRequest)

        assertEquals(listOf(ProviderVoice(locale = "de-AT")), contexts.map { it.voice })
        assertEquals(
            listOf(
                Triple("a_bound_to_network", AttemptOutcome.Failed, IndeRunErrorClass.CapabilityMismatch),
                Triple("b_local", AttemptOutcome.Succeeded, null),
            ),
            result.provenance!!.attempts.map { Triple(it.providerId, it.outcome, it.errorClass) },
        )
    }

    @Test
    fun speechRequestWithoutSpeechFailsValidation() = runTest {
        val issues = validationIssues(speechRequest.copy(speech = null))

        assertEquals(listOf("speech is required for task.kind 'text_to_speech'."), issues)
    }

    @Test
    fun speechRequestWithAPromptFailsValidation() = runTest {
        val issues = validationIssues(speechRequest.copy(prompt = "Hallo"))

        assertEquals(listOf("prompt is not allowed for task.kind 'text_to_speech'."), issues)
    }

    @Test
    fun validSpeechRequestPassesValidation() = runTest {
        val registry = ProviderRegistry().apply {
            register(ListedVoiceSpeechProvider(id = "local_speech", voices = listOf(ProviderVoice(locale = "de-AT")), contexts = mutableListOf()))
        }

        val result = IndeRun(registry, hostServices).run(speechRequest)

        assertEquals("local_speech", result.telemetry.providerUsed)
    }

    private suspend fun validationIssues(request: TaskRequest): List<*> {
        val registry = ProviderRegistry().apply {
            register(ListedVoiceSpeechProvider(id = "local_speech", voices = emptyList(), contexts = mutableListOf()))
        }
        val failure = runCatching { IndeRun(registry, hostServices).run(request) }.exceptionOrNull() as? IndeRunException
            ?: error("Expected a validation failure")
        assertEquals(IndeRunErrorClass.Internal, failure.errorClass)
        assertTrue(failure.message.startsWith("Validation failed"))
        return failure.details!!["validationIssues"] as List<*>
    }

    /**
     * Replaces the engine's router with one planning through [plan]. The route planner is
     * internal to `inderun-core` (there is no second planner to swap in), so the test reaches
     * it by reflection, as the Web SDK's test does with `Reflect.set`.
     */
    private fun injectPlanner(engine: IndeRun, registry: ProviderRegistry, plan: (RoutePlannerInput) -> RoutePlan) {
        val plannerType = Class.forName("app.independo.inderun.core.RoutePlanner")
        val planner = Proxy.newProxyInstance(plannerType.classLoader, arrayOf(plannerType)) { proxy, method, args ->
            when (method.name) {
                "planRoute" -> plan(args!![0] as RoutePlannerInput)
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

    /** A speech provider listing [voices], recording each context it is run with. */
    private class ListedVoiceSpeechProvider(
        private val id: String,
        private val voices: List<ProviderVoice>,
        private val contexts: MutableList<RunContext>,
    ) : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = id,
            type = ProviderType.Local,
            transport = ProviderTransport.SystemService,
            supports = supports(),
            cancel = CancelSemantics.Hard,
            tasks = listOf("text_to_speech"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_speech",
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(run = true, stream = false),
                    cancel = CancelSemantics.Hard,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                    locales = listOf("de-AT", "de-DE"),
                ),
            ),
            privacy = ProviderPrivacy(dataLeavesDevice = false),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(ProviderTaskAvailability(kind = "text_to_speech", voices = voices)),
        )

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            contexts += context
            return TaskResult(
                finishReason = FinishReason.STOP,
                output = TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput()),
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
            )
        }
    }

    /** Declares only `text_to_speech`. Its id sorts first, so only its declarations keep it out of a text route. */
    private class SpeechOnlyProvider : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = "a_speech_only",
            type = ProviderType.Local,
            transport = ProviderTransport.SystemService,
            supports = supports(),
            cancel = CancelSemantics.Hard,
            tasks = listOf("text_to_speech"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_speech",
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(run = true, stream = false),
                    cancel = CancelSemantics.Hard,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                ),
            ),
            privacy = ProviderPrivacy(dataLeavesDevice = false),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(
                ProviderTaskAvailability(kind = "text_to_speech", voices = listOf(ProviderVoice(locale = "de-DE"))),
            ),
        )

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = error("A text request must never reach a speech-only provider")
    }

    /** Declares `text_to_text` explicitly but accepts only image input. Its id sorts first. */
    private class ImageOnlyTextProvider : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = "a_image_only",
            type = ProviderType.Local,
            transport = ProviderTransport.InProcess,
            supports = supports(),
            cancel = CancelSemantics.Soft,
            tasks = listOf("text_to_text"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_text",
                    inputs = listOf(TaskInputKind.Image),
                    interaction = ProviderTaskInteraction(run = true, stream = false),
                    cancel = CancelSemantics.Soft,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Inline)),
                ),
            ),
            privacy = ProviderPrivacy(dataLeavesDevice = false),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = error("A text prompt must never reach a provider that only accepts images")
    }

    private class TextProvider : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = "z_text",
            type = ProviderType.Local,
            transport = ProviderTransport.InProcess,
            supports = supports(),
            cancel = CancelSemantics.Soft,
            tasks = listOf("text_to_text"),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = TaskOutput(type = TaskOutputType.TEXT, text = "Hello"),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = "z_text", totalMs = 0.0),
        )
    }

    private companion object {
        fun supports() = ProviderSupports(
            run = true,
            streaming = false,
            realtime = false,
            tools = false,
            reasoningEvents = false,
            structuredOutput = false,
            multimodal = false,
        )
    }
}
