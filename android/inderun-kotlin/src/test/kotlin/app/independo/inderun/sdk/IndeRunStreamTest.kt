package app.independo.inderun.sdk

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiAvailability
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiFinishReason
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiGenerationOptions
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiOutput
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiProvider
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiRuntime
import com.google.mlkit.genai.common.GenAiException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android-specific Mode 2 coverage.
 *
 * The behavior every engine shares -- ordering, terminal outcomes, cancellation
 * races, routing rejections, fallback, provider faults and stream telemetry --
 * lives in [IndeRunStreamConformanceTest], driven by the cross-SDK catalog at
 * `contracts/fixtures/streaming/engine-conformance.json`. Those cases used to be
 * duplicated here and hand-copied between the three SDKs, which is how they
 * drifted apart in the first place.
 *
 * What remains is what only Android can prove: that the registered ML Kit GenAI
 * provider actually routes and streams through the real adapter, rather than a
 * fake one standing in for it.
 */
@RunWith(RobolectricTestRunner::class)
class IndeRunStreamTest {
    private fun localRequiredRequest() = conformanceRequest(privacy = PrivacyEnum.LocalRequired)

    @Test
    fun streamsMlKitDeltasThroughTheEngineUnderLocalRequired() = runTest {
        // The adapter suite proves the ML Kit adapter's own contract against its
        // runtime seam; this proves the registered provider actually routes and
        // streams — planner, Event Gate and all — for a local-only request.
        val registry = ProviderRegistry().apply {
            register(
                AndroidMlKitGenAiProvider(
                    id = AndroidMlKitGenAiProvider.DEFAULT_ID,
                    runtime = FakeMlKitRuntime(
                        listOf(
                            AndroidMlKitGenAiOutput("Hello"),
                            AndroidMlKitGenAiOutput(" world", AndroidMlKitGenAiFinishReason.STOP),
                        ),
                    ),
                ),
            )
        }

        val run = IndeRun(registry, conformanceHostServices()).stream(localRequiredRequest())
        val events = run.events.toList()

        assertEquals(AndroidMlKitGenAiProvider.DEFAULT_ID, run.handle.providerId)
        assertEquals(listOf("content_delta", "content_delta", "terminal"), events.map { it.type })
        assertEquals(listOf(0L, 1L, 2L), events.map { it.sequence })
        assertEquals(Outcome.Completed, events.last().payload?.outcome)
        assertEquals("Hello world", events.last().payload?.finalText)
        assertEquals(FinishReason.STOP, events.last().payload?.finishReason)
    }

    @Test
    fun cancellingAnMlKitEngineStreamProducesACancelledTerminalWithPartialText() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                AndroidMlKitGenAiProvider(
                    id = AndroidMlKitGenAiProvider.DEFAULT_ID,
                    runtime = FakeMlKitRuntime(
                        listOf(
                            AndroidMlKitGenAiOutput("one"),
                            AndroidMlKitGenAiOutput(" two", AndroidMlKitGenAiFinishReason.STOP),
                        ),
                        delayMs = 50,
                    ),
                ),
            )
        }

        val run = IndeRun(registry, conformanceHostServices()).stream(localRequiredRequest())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") run.cancel("user stopped")
        }

        assertEquals(listOf("content_delta", "terminal"), events.map { it.type })
        assertEquals(1, events.count { it.type == "terminal" })
        assertEquals(Outcome.Cancelled, events.last().payload?.outcome)
        assertEquals("one", events.last().payload?.partialText)
        assertEquals("user stopped", events.last().payload?.reason)
    }

    @Test
    fun anMlKitPolicyRejectionRetractsDeliveredContentThroughTheEngine() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                AndroidMlKitGenAiProvider(
                    id = AndroidMlKitGenAiProvider.DEFAULT_ID,
                    runtime = FakeMlKitRuntime(
                        listOf(AndroidMlKitGenAiOutput("half a sentence")),
                        failure = GenAiException(
                            "policy",
                            IllegalStateException("policy"),
                            GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
                        ),
                    ),
                ),
            )
        }

        val events = IndeRun(registry, conformanceHostServices()).stream(localRequiredRequest()).events.toList()

        // The retraction reaches the caller as a real content event, and the
        // terminal that follows carries none of the rejected text.
        assertEquals(listOf("content_delta", "content_snapshot", "terminal"), events.map { it.type })
        assertEquals("", events[1].payload?.text)
        assertEquals(Outcome.Error, events.last().payload?.outcome)
        assertEquals("", events.last().payload?.partialText)
        assertEquals(IndeRunErrorClass.CapabilityMismatch, events.last().payload?.error?.errorClass)
    }
}

/**
 * Stands in for Gemini Nano so the ML Kit engine streams above exercise the
 * real adapter, planner and Event Gate without an AICore device. [delayMs] spaces
 * the chunks out on virtual time, which is what lets a test cancel between them.
 */
private class FakeMlKitRuntime(
    private val outputs: List<AndroidMlKitGenAiOutput>,
    private val delayMs: Long = 0,
    private val failure: Throwable? = null,
) : AndroidMlKitGenAiRuntime {
    override suspend fun availability(): AndroidMlKitGenAiAvailability = AndroidMlKitGenAiAvailability.Available

    override suspend fun generateText(
        prompt: String,
        options: AndroidMlKitGenAiGenerationOptions,
    ): AndroidMlKitGenAiOutput = outputs.first()

    override fun generateTextStream(
        prompt: String,
        options: AndroidMlKitGenAiGenerationOptions,
    ): Flow<AndroidMlKitGenAiOutput> = flow {
        outputs.forEach { output ->
            if (delayMs > 0) delay(delayMs)
            emit(output)
        }
        failure?.let { throw it }
    }
}
