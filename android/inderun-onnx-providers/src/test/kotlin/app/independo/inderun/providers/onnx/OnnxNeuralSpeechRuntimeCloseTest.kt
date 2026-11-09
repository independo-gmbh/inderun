package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import app.independo.inderun.providers.neuralspeech.SpeechGraphExecutor
import app.independo.inderun.providers.neuralspeech.SpeechTensor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Counts how often it is closed; never reaches ONNX Runtime. */
private class CountingExecutor : SpeechGraphExecutor {
    val closes = AtomicInteger()

    override suspend fun load(graphs: Map<String, String>) = Unit

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> = emptyMap()

    override fun close() {
        closes.incrementAndGet()
    }
}

/** An executor whose load and run block on gates, to hold a call in flight. */
private class GatedExecutor(private val loadGate: CompletableDeferred<Unit>? = null, private val runGate: CompletableDeferred<Unit>? = null) : SpeechGraphExecutor {
    val closes = AtomicInteger()
    val entered = CompletableDeferred<Unit>()

    override suspend fun load(graphs: Map<String, String>) {
        entered.complete(Unit)
        loadGate?.await()
    }

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> {
        entered.complete(Unit)
        runGate?.await()
        return emptyMap()
    }

    override fun close() {
        closes.incrementAndGet()
    }
}

/** A pipeline stand-in that drives [body] against the runtime's (guarded) executor. */
private class ScriptedPipeline(
    private val executor: SpeechGraphExecutor,
    private val onPrepare: suspend (SpeechGraphExecutor) -> Unit = {},
    private val body: suspend kotlinx.coroutines.flow.FlowCollector<PcmChunk>.(SpeechGraphExecutor) -> Unit = {},
) : NeuralSpeechRuntime {
    override suspend fun availability(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability {
        onPrepare(executor)
        return NeuralSpeechAvailability(true)
    }

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow { body(executor) }
}

private fun chunk(isLast: Boolean) = PcmChunk(ShortArray(4), 24000, isLast)

class OnnxNeuralSpeechRuntimeCloseTest {
    private val context: Context
        get() {
            val unsafeField = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }
            val unsafe = unsafeField.get(null) as sun.misc.Unsafe
            return unsafe.allocateInstance(android.content.ContextWrapper::class.java) as Context
        }

    private val executors = CopyOnWriteArrayList<CountingExecutor>()

    private fun runtime() = OnnxNeuralSpeechRuntime(
        context,
        OnnxNeuralSpeechRuntimeOptions(),
        { _, _ -> CountingExecutor().also { executors += it } },
        { executor, directory ->
            app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntime(
                app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntimeOptions(
                    executor = executor,
                    files = app.independo.inderun.providers.neuralspeech.DirectoryPackageFiles(directory),
                ),
            )
        },
    )

    private fun speechPackage(version: String) = ModelPackage(
        id = "t",
        version = version,
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.Filesystem, ref = "/nonexistent"),
        speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = 24000,
            graphs = mapOf("text" to "text.onnx"),
            frontend = SpeechFrontend(kind = FrontendKind.Grapheme),
            voices = emptyList(),
        ),
    )

    /** Waits for the execution thread, where executor teardown is scheduled, to run what was queued before. */
    private fun drainExecutionThread() {
        val reached = CountDownLatch(1)
        OnnxExecutionDispatcher.dispatcher.executor.execute { reached.countDown() }
        assertTrue(reached.await(5, TimeUnit.SECONDS))
    }

    private fun assertRuntimeClosed(error: NeuralSpeechRuntimeError) {
        assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
        assertEquals("runtime closed", error.message)
        assertEquals("runtime_closed", error.code)
    }

    @Test
    fun closeReleasesEveryCachedExecutorExactlyOnce() = runTest {
        val runtime = runtime()
        runtime.availability(speechPackage("1"))
        runtime.availability(speechPackage("2"))
        assertEquals(2, executors.size)

        runtime.close()
        drainExecutionThread()

        assertEquals(listOf(1, 1), executors.map { it.closes.get() })
    }

    @Test
    fun closeIsIdempotentUnderConcurrentCalls() = runTest {
        val runtime = runtime()
        runtime.availability(speechPackage("1"))
        val threads = List(2) { Thread { runtime.close() } }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        runtime.close()
        drainExecutionThread()

        assertEquals(listOf(1), executors.map { it.closes.get() })
    }

    @Test
    fun afterCloseAvailabilityPrepareAndSynthesizeReportRuntimeClosed() = runTest {
        val runtime = runtime()
        runtime.close()
        val pkg = speechPackage("1")

        assertEquals(NeuralSpeechAvailability(false, "runtime closed"), runtime.availability(pkg))
        for (call in listOf<suspend () -> Unit>(
            { runtime.prepare(pkg) },
            { runtime.synthesize(NeuralSpeechSynthesisInput(pkg, "a", "de", "v")).toList() },
        )) {
            try {
                call()
                fail("expected runtime_closed")
            } catch (error: NeuralSpeechRuntimeError) {
                assertRuntimeClosed(error)
            }
        }
    }

    @Test
    fun afterCloseNothingIsCreatedAndNormalizeTextReturnsTheTextUnchanged() = runTest {
        val runtime = runtime()
        runtime.close()
        val pkg = speechPackage("1")

        runtime.availability(pkg)
        try {
            runtime.prepare(pkg)
        } catch (_: NeuralSpeechRuntimeError) {
        }

        assertTrue(executors.isEmpty())
        assertEquals("Am 3. Mai.", runtime.normalizeText(pkg, "Am 3. Mai.", "de-DE"))
    }

    private fun scripted(
        executor: GatedExecutor,
        onPrepare: suspend (SpeechGraphExecutor) -> Unit = {},
        body: suspend kotlinx.coroutines.flow.FlowCollector<PcmChunk>.(SpeechGraphExecutor) -> Unit = {},
    ) = OnnxNeuralSpeechRuntime(
        context,
        OnnxNeuralSpeechRuntimeOptions(),
        { _, _ -> executor },
        { guarded, _ -> ScriptedPipeline(guarded, onPrepare, body) },
    )

    private val input get() = NeuralSpeechSynthesisInput(speechPackage("1"), "a", "de", "v")

    @Test
    fun closeDuringAGraphCallWaitsForItAndThenTheSynthesisEndsWithRuntimeClosed() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val executor = GatedExecutor(runGate = gate)
        val runtime = scripted(executor, body = {
            it.run("dit_step", emptyMap())
            emit(chunk(false))
            emit(chunk(true))
        })

        val synthesis = async(Dispatchers.Default) { runCatching { runtime.synthesize(input).toList() } }
        withTimeout(5000) { executor.entered.await() }
        runtime.close()
        delay(150)

        assertEquals("executor released under a running graph call", 0, executor.closes.get())
        assertTrue(synthesis.isActive)

        gate.complete(Unit)
        val outcome = withTimeout(5000) { synthesis.await() }
        val error = outcome.exceptionOrNull() as? NeuralSpeechRuntimeError
        assertTrue(outcome.toString(), error != null)
        assertRuntimeClosed(error!!)
        assertEquals(1, executor.closes.get())
    }

    @Test
    fun aSentenceWhoseLastChunkWasDeliveredCompletesAfterClose() = runBlocking {
        val executor = GatedExecutor()
        val runtime = scripted(executor, body = {
            it.run("dit_step", emptyMap())
            emit(chunk(true))
            it.run("late", emptyMap())
        })
        val delivered = mutableListOf<PcmChunk>()

        runtime.synthesize(input).collect {
            delivered += it
            runtime.close()
        }

        assertEquals(listOf(true), delivered.map { it.isLast })
        assertEquals(1, executor.closes.get())
    }

    @Test
    fun aCollectorFailureIsNotRemappedAfterClose() = runBlocking {
        val executor = GatedExecutor()
        val runtime = scripted(executor, body = { emit(chunk(true)) })
        try {
            runtime.synthesize(input).collect {
                runtime.close()
                throw IllegalStateException("collector failed")
            }
            fail("expected the collector's failure")
        } catch (error: IllegalStateException) {
            assertEquals("collector failed", error.message)
        }
    }

    @Test
    fun closeDuringALoadReleasesTheLoadedResourcesOnceAndTheCallerGetsRuntimeClosed() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val executor = GatedExecutor(loadGate = gate)
        val runtime = scripted(executor, onPrepare = { it.load(emptyMap()) })

        val preparation = async(Dispatchers.Default) { runCatching { runtime.prepare(speechPackage("1")) } }
        withTimeout(5000) { executor.entered.await() }
        runtime.close()
        delay(150)
        assertEquals("executor released under a running load", 0, executor.closes.get())

        gate.complete(Unit)
        val error = withTimeout(5000) { preparation.await() }.exceptionOrNull() as? NeuralSpeechRuntimeError
        assertTrue(error != null)
        assertRuntimeClosed(error!!)
        assertEquals(1, executor.closes.get())
    }
}
