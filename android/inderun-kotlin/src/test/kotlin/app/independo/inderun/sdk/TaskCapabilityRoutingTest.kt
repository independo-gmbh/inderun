package app.independo.inderun.sdk

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.OutputDelivery
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
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Per-task provider capabilities through the real Rust planner (#243). The planner semantics are
 * pinned by the shared vectors in `contracts/fixtures/routing/`; these tests check that the Kotlin
 * engine hands the planner the per-task declarations and surfaces them.
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
            output = Output(text = "Hello"),
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
