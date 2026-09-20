package app.independo.inderun.providers.mlkit

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Generation
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamCancellationToken
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createUnavailable
import com.google.mlkit.genai.common.GenAiException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration

/**
 * Mode 2 suite for the ML Kit adapter, split from the Mode 1 suite the way the
 * OpenAI module splits its two.
 *
 * Everything here is driven through the [AndroidMlKitGenAiRuntime] seam, so it
 * proves the adapter's event, error and cancellation contract — not that ML Kit
 * itself chunks, reports finish reasons, or stops generating the way this assumes.
 * Only the on-device smoke test in `android/inderun-demo-app/README.md` covers that.
 */
class AndroidMlKitGenAiProviderStreamTest {

    @Test
    fun describesStreamingWithAChunkStreamingStyle() {
        val adapter: ProviderAdapter = provider(ScriptedMlKitGenAiRuntime())

        val descriptor = adapter.describe()

        assertTrue(descriptor.supports.streaming)
        assertEquals(ProviderDescriptor.StreamingStyle.chunks, descriptor.streamingStyle)
        assertEquals(ProviderDescriptor.CancelSemantics.soft, descriptor.cancel)
        // Declaring streaming without implementing it is a routing-visible
        // mistake, so the type is asserted alongside the flag.
        assertTrue(adapter is StreamingProviderAdapter)
    }

    @Test
    fun doesNotReportASeparateStreamingRestrictionWhenTheModelIsAvailable() = runTest {
        val provider = provider(ScriptedMlKitGenAiRuntime())

        val capabilities = provider.capabilities(fakeHostServices())

        assertTrue(capabilities.available)
        assertNull(capabilities.streamingAvailable)
        assertNull(capabilities.streamingUnavailableReason)
    }

    @Test
    fun reportsADownloadingModelAsProviderUnavailableNotStreamingUnavailable() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                availability = { AndroidMlKitGenAiAvailability.Downloading("Gemini Nano is currently downloading.") },
            ),
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertFalse(capabilities.available)
        assertEquals("Gemini Nano is currently downloading.", capabilities.reason)
        assertNull(capabilities.streamingAvailable)
    }

    @Test
    fun emitsOneDeltaPerChunkAndCompletesWithTheConcatenation() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(
                    AndroidMlKitGenAiOutput("Bon"),
                    AndroidMlKitGenAiOutput("jour"),
                    AndroidMlKitGenAiOutput(" tout", AndroidMlKitGenAiFinishReason.STOP),
                ),
            ),
        )

        val events = provider.stream(request(), streamContext()).toList()

        assertEquals(
            listOf("Bon", "jour", " tout"),
            events.filterIsInstance<ProviderStreamEvent.Delta>().map { it.text },
        )
        val done = events.last() as ProviderStreamEvent.Done
        assertEquals("Bonjour tout", done.finalText)
        assertEquals(FinishReason.STOP, done.finishReason)
        assertNull(done.usage)
    }

    @Test
    fun normalizesMessagesIntoASinglePromptAndForwardsGenerationOptions() = runTest {
        val runtime = ScriptedMlKitGenAiRuntime(outputs = listOf(AndroidMlKitGenAiOutput("ok")))
        val request = TaskRequest(
            schemaVersion = SchemaVersion.V1_0,
            messages = listOf(
                Message(MessageRole.SYSTEM, "Be concise"),
                Message(MessageRole.USER, "Hello"),
            ),
            task = TaskRequestTask(),
            constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            generation = Generation(maxOutputTokens = 64, temperature = 0.5, seed = 7),
        )

        provider(runtime).stream(request, streamContext()).toList()

        assertEquals("system: Be concise\nuser: Hello", runtime.lastPrompt)
        assertEquals(
            AndroidMlKitGenAiGenerationOptions(maxOutputTokens = 64, temperature = 0.5, seed = 7),
            runtime.lastOptions,
        )
    }

    @Test
    fun reportsLengthWhenMlKitFinishesOnMaxTokens() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(AndroidMlKitGenAiOutput("truncated", AndroidMlKitGenAiFinishReason.MAX_TOKENS)),
            ),
        )

        val done = provider.stream(request(), streamContext()).toList().last() as ProviderStreamEvent.Done

        assertEquals(FinishReason.LENGTH, done.finishReason)
    }

    @Test
    fun fallsBackToStopWhenMlKitNeverReportsAFinishReason() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(outputs = listOf(AndroidMlKitGenAiOutput("done"))),
        )

        val done = provider.stream(request(), streamContext()).toList().last() as ProviderStreamEvent.Done

        assertEquals(FinishReason.STOP, done.finishReason)
    }

    @Test
    fun carriesAFinishReasonFromAChunkWithNoNewText() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(
                    AndroidMlKitGenAiOutput("partial"),
                    AndroidMlKitGenAiOutput("", AndroidMlKitGenAiFinishReason.MAX_TOKENS),
                ),
            ),
        )

        val events = provider.stream(request(), streamContext()).toList()

        assertEquals(1, events.filterIsInstance<ProviderStreamEvent.Delta>().size)
        val done = events.last() as ProviderStreamEvent.Done
        assertEquals("partial", done.finalText)
        assertEquals(FinishReason.LENGTH, done.finishReason)
    }

    @Test
    fun throwsCapabilityMismatchForEachNonAvailableStateWithoutEmittingAnything() = runTest {
        val states = listOf(
            AndroidMlKitGenAiAvailability.Downloadable("download pending"),
            AndroidMlKitGenAiAvailability.Downloading("downloading"),
            AndroidMlKitGenAiAvailability.Unavailable("not supported"),
        )

        for (state in states) {
            val provider = provider(
                ScriptedMlKitGenAiRuntime(
                    availability = { state },
                    outputs = listOf(AndroidMlKitGenAiOutput("never")),
                ),
            )
            val events = mutableListOf<ProviderStreamEvent>()

            val error = assertFailsWithIndeRun {
                provider.stream(request(), streamContext()).collect { events += it }
            }

            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals(AndroidMlKitGenAiProvider.DEFAULT_ID, error.providerId)
            assertEquals("run_123", error.runId)
            assertTrue(events.isEmpty())
        }
    }

    @Test
    fun rechecksAvailabilityWhenTheStreamIsCollectedNotWhenItIsBuilt() = runTest {
        var availability: AndroidMlKitGenAiAvailability = AndroidMlKitGenAiAvailability.Available
        val provider = provider(ScriptedMlKitGenAiRuntime(availability = { availability }))

        val stream = provider.stream(request(), streamContext())
        availability = AndroidMlKitGenAiAvailability.Unavailable("AICore stopped")

        val error = assertFailsWithIndeRun { stream.toList() }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
    }

    @Test
    fun keepsEarlierDeltasWhenAMidStreamFailureIsNotAPolicyRejection() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(AndroidMlKitGenAiOutput("half")),
                failure = IllegalStateException("boom"),
            ),
        )
        val events = mutableListOf<ProviderStreamEvent>()

        val error = assertFailsWithIndeRun {
            provider.stream(request(), streamContext()).collect { events += it }
        }

        assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        assertEquals(listOf("half"), events.filterIsInstance<ProviderStreamEvent.Delta>().map { it.text })
        // Only a policy rejection retracts; a mechanical failure leaves whatever
        // was legitimately generated in the caller's hands.
        assertTrue(events.none { it is ProviderStreamEvent.Snapshot })
        assertTrue(events.none { it is ProviderStreamEvent.Done })
    }

    @Test
    fun retractsDeliveredContentWhenMlKitRejectsTheResponseOnPolicy() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(AndroidMlKitGenAiOutput("half a "), AndroidMlKitGenAiOutput("sentence")),
                failure = genAiException(GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR),
            ),
        )
        val events = mutableListOf<ProviderStreamEvent>()

        val error = assertFailsWithIndeRun {
            provider.stream(request(), streamContext()).collect { events += it }
        }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals(
            listOf("half a ", "sentence"),
            events.filterIsInstance<ProviderStreamEvent.Delta>().map { it.text },
        )
        // The retraction is the last thing emitted: an empty snapshot resets the
        // run's cumulative text so the rejected output does not survive the error.
        val last = events.last()
        assertTrue("expected a retraction snapshot, got $last", last is ProviderStreamEvent.Snapshot)
        assertEquals("", (last as ProviderStreamEvent.Snapshot).text)
    }

    @Test
    fun doesNotEmitARetractionWhenAPolicyRejectionArrivesBeforeAnyContent() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                failure = genAiException(GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR),
            ),
        )
        val events = mutableListOf<ProviderStreamEvent>()

        val error = assertFailsWithIndeRun {
            provider.stream(request(), streamContext()).collect { events += it }
        }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertTrue(events.isEmpty())
    }

    @Test
    fun mapsPolicyRejectionsToCapabilityMismatch() = runTest {
        val codes = listOf(
            GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR,
            GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
        )

        for (code in codes) {
            val provider = provider(ScriptedMlKitGenAiRuntime(failure = genAiException(code)))

            val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

            assertEquals("code $code", IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals(code, error.details?.get("mlKitErrorCode"))
        }
    }

    @Test
    fun reportsErrorWhenMlKitStopsForSomeOtherReason() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(
                outputs = listOf(AndroidMlKitGenAiOutput("cut short", AndroidMlKitGenAiFinishReason.OTHER)),
            ),
        )

        val done = provider.stream(request(), streamContext()).toList().last() as ProviderStreamEvent.Done

        // `OTHER` is "all other reasons that stopped the generation" — not the
        // natural end `stop` claims.
        assertEquals(FinishReason.ERROR, done.finishReason)
        assertEquals("cut short", done.finalText)
    }

    @Test
    fun preservesAnAlreadyNormalizedIndeRunException() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(failure = createUnavailable(message = "runtime went away")),
        )

        val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

        assertEquals(IndeRunErrorClass.Unavailable, error.errorClass)
        assertEquals("runtime went away", error.message)
        assertEquals(AndroidMlKitGenAiProvider.DEFAULT_ID, error.providerId)
    }

    @Test
    fun mapsGenAiBusyToRateLimitedWithMlKitsRetryDelay() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(failure = genAiException(GenAiException.ErrorCode.BUSY, Duration.ofSeconds(2))),
        )

        val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

        assertEquals(IndeRunErrorClass.RateLimited, error.errorClass)
        assertEquals(2_000L, error.retryAfterMs)
    }

    @Test
    fun omitsTheRetryDelayWhenMlKitReportsNone() = runTest {
        val provider = provider(
            ScriptedMlKitGenAiRuntime(failure = genAiException(GenAiException.ErrorCode.BUSY)),
        )

        val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

        assertEquals(IndeRunErrorClass.RateLimited, error.errorClass)
        assertNull(error.retryAfterMs)
    }

    @Test
    fun mapsDeviceCapabilityErrorCodesToCapabilityMismatch() = runTest {
        val codes = listOf(
            GenAiException.ErrorCode.NOT_AVAILABLE,
            GenAiException.ErrorCode.NOT_SUPPORTED,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE,
            GenAiException.ErrorCode.REQUEST_TOO_LARGE,
            GenAiException.ErrorCode.REQUEST_TOO_SMALL,
        )

        for (code in codes) {
            val provider = provider(ScriptedMlKitGenAiRuntime(failure = genAiException(code)))

            val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

            assertEquals("code $code", IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals(code, error.details?.get("mlKitErrorCode"))
        }
    }

    @Test
    fun mapsUnclassifiedErrorCodesToInternal() = runTest {
        val codes = listOf(
            GenAiException.ErrorCode.UNKNOWN,
            GenAiException.ErrorCode.CACHE_PROCESSING_ERROR,
        )

        for (code in codes) {
            val provider = provider(ScriptedMlKitGenAiRuntime(failure = genAiException(code)))

            val error = assertFailsWithIndeRun { provider.stream(request(), streamContext()).toList() }

            assertEquals("code $code", IndeRunErrorClass.Internal, error.errorClass)
        }
    }

    @Test
    fun runAndStreamClassifyTheSameMlKitFailureIdentically() = runTest {
        val failure = genAiException(GenAiException.ErrorCode.BUSY, Duration.ofSeconds(3))

        val fromRun = assertFailsWithIndeRun {
            provider(ScriptedMlKitGenAiRuntime(failure = failure))
                .run(request(), RunContext("run_123", fakeHostServices()))
        }
        val fromStream = assertFailsWithIndeRun {
            provider(ScriptedMlKitGenAiRuntime(failure = failure))
                .stream(request(), streamContext()).toList()
        }

        assertEquals(fromRun.errorClass, fromStream.errorClass)
        assertEquals(fromRun.retryAfterMs, fromStream.retryAfterMs)
        assertEquals(fromRun.message, fromStream.message)
    }

    @Test
    fun stopsEmittingOnceTheCallersTokenIsCancelled() = runTest {
        val cancellation = StreamCancellationToken()
        val runtime = ScriptedMlKitGenAiRuntime(
            outputs = listOf(AndroidMlKitGenAiOutput("one"), AndroidMlKitGenAiOutput("two")),
            gateBefore = 1,
        )
        val events = mutableListOf<ProviderStreamEvent>()

        provider(runtime).stream(request(), streamContext(cancellation)).collect { event ->
            events += event
            cancellation.cancel("user stopped")
            runtime.releaseGate()
        }

        assertEquals(listOf("one"), events.filterIsInstance<ProviderStreamEvent.Delta>().map { it.text })
        // The engine, not the provider, owns the cancelled terminal.
        assertTrue(events.none { it is ProviderStreamEvent.Done })
    }

    @Test
    fun tearsDownTheRuntimeFlowWhenTheCollectorIsCancelled() = runTest {
        val runtime = ScriptedMlKitGenAiRuntime(parkForever = true)
        val job = launch {
            provider(runtime).stream(request(), streamContext()).collect { }
        }
        runtime.awaitParked()

        job.cancelAndJoin()

        assertTrue(runtime.tornDown)
    }

    @Test
    fun producesNoEventsWhenTheTokenIsAlreadyCancelledBeforeCollection() = runTest {
        val cancellation = StreamCancellationToken().apply { cancel("before") }
        val provider = provider(
            ScriptedMlKitGenAiRuntime(outputs = listOf(AndroidMlKitGenAiOutput("never"))),
        )

        val events = provider.stream(request(), streamContext(cancellation)).toList()

        assertTrue(events.isEmpty())
    }

    private fun provider(runtime: AndroidMlKitGenAiRuntime) = AndroidMlKitGenAiProvider(
        id = AndroidMlKitGenAiProvider.DEFAULT_ID,
        runtime = runtime,
    )

    private fun request(): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Hello",
        task = TaskRequestTask(),
        constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
    )

    private fun streamContext(
        cancellation: StreamCancellationToken = StreamCancellationToken(),
    ): ProviderStreamContext = ProviderStreamContext(
        runId = "run_123",
        hostServices = fakeHostServices(),
        cancellation = cancellation,
    )

    private fun genAiException(code: Int, retryDelay: Duration? = null): GenAiException {
        val cause = IllegalStateException("ml kit failed")
        return if (retryDelay == null) {
            GenAiException("ml kit failed", cause, code)
        } else {
            GenAiException("ml kit failed", cause, code, retryDelay)
        }
    }

    private inline fun assertFailsWithIndeRun(block: () -> Unit): IndeRunException {
        try {
            block()
        } catch (error: IndeRunException) {
            return error
        }
        throw AssertionError("Expected an IndeRunException.")
    }

    private fun fakeHostServices(): HostServices = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis(): Long = 1_000L
        },
    )

    /**
     * Scripted stand-in for the ML Kit runtime.
     *
     * [gateBefore] parks the stream immediately before the chunk at that index so a
     * test can cancel between two chunks deterministically, and [parkForever] never
     * emits at all so cancellation can be observed while the stream is blocked. Both
     * use coroutine primitives rather than wall-clock sleeps, so the ordering is a
     * guarantee rather than a race.
     */
    private class ScriptedMlKitGenAiRuntime(
        private val availability: () -> AndroidMlKitGenAiAvailability = { AndroidMlKitGenAiAvailability.Available },
        private val outputs: List<AndroidMlKitGenAiOutput> = emptyList(),
        private val failure: Throwable? = null,
        private val gateBefore: Int? = null,
        private val parkForever: Boolean = false,
    ) : AndroidMlKitGenAiRuntime {
        var lastPrompt: String? = null
            private set
        var lastOptions: AndroidMlKitGenAiGenerationOptions? = null
            private set

        @Volatile
        var tornDown = false
            private set

        private val gate = CompletableDeferred<Unit>()
        private val parked = CompletableDeferred<Unit>()

        fun releaseGate() {
            gate.complete(Unit)
        }

        /** Suspends until the stream has actually parked, so cancelling it is not a race. */
        suspend fun awaitParked() {
            parked.await()
        }

        override suspend fun availability(): AndroidMlKitGenAiAvailability = availability.invoke()

        override suspend fun generateText(
            prompt: String,
            options: AndroidMlKitGenAiGenerationOptions,
        ): AndroidMlKitGenAiOutput {
            lastPrompt = prompt
            lastOptions = options
            failure?.let { throw it }
            return outputs.firstOrNull() ?: AndroidMlKitGenAiOutput("")
        }

        override fun generateTextStream(
            prompt: String,
            options: AndroidMlKitGenAiGenerationOptions,
        ): Flow<AndroidMlKitGenAiOutput> = flow {
            lastPrompt = prompt
            lastOptions = options
            try {
                if (parkForever) {
                    parked.complete(Unit)
                    awaitCancellation()
                }
                outputs.forEachIndexed { index, output ->
                    if (index == gateBefore) gate.await()
                    emit(output)
                }
                failure?.let { throw it }
            } finally {
                tornDown = true
            }
        }
    }
}
