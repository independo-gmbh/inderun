package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.Limits
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * None of these reach ONNX Runtime (its native library is not loadable on the JVM) or touch the
 * context, so a constructor-less one is enough, as in [OnnxFormatGuardTest].
 */
class OnnxSpeechGraphExecutorTest {
    private val tmpDir: String = requireNotNull(System.getProperty("java.io.tmpdir"))

    private val context: Context
        get() {
            val unsafeField = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }
            val unsafe = unsafeField.get(null) as sun.misc.Unsafe
            return unsafe.allocateInstance(android.content.ContextWrapper::class.java) as Context
        }

    @Test
    fun closedSessionsAreClosedOnTheExecutionThreadAfterQueuedRuns() {
        val running = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = CountDownLatch(1)
        var closedOn: String? = null
        // Stands in for a run in flight on the execution thread.
        OnnxExecutionDispatcher.dispatcher.executor.execute {
            running.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        assertTrue(running.await(5, TimeUnit.SECONDS))
        closeOnExecutionThread(
            listOf {
                closedOn = Thread.currentThread().name
                closed.countDown()
            },
        )
        assertFalse("closed while a run was in flight", closed.await(100, TimeUnit.MILLISECONDS))
        release.countDown()
        assertTrue(closed.await(5, TimeUnit.SECONDS))
        assertEquals("inderun-onnx-execution", closedOn)
    }

    @Test
    fun runBeforeLoadIsInternal() = runTest {
        val executor = OnnxSpeechGraphExecutor(File(tmpDir))
        try {
            executor.run("text", emptyMap())
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
            assertEquals("graph not loaded: text", error.message)
        }
    }

    @Test
    fun loadReportsAMissingGraphFile() = runTest {
        val directory = File(tmpDir, UUID.randomUUID().toString())
        val executor = OnnxSpeechGraphExecutor(directory)
        try {
            executor.load(mapOf("text" to "text.onnx"))
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
            assertEquals("graph failed to load: text: model files missing: text.onnx", error.message)
        }
    }

    @Test
    fun loadRefusesAGraphFileNameOutsideThePackage() = runTest {
        val executor = OnnxSpeechGraphExecutor(File(tmpDir))
        for (name in listOf("../text.onnx", "/etc/text.onnx", "")) {
            try {
                executor.load(mapOf("text" to name))
                fail("expected '$name' to be refused")
            } catch (error: NeuralSpeechRuntimeError) {
                assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
                assertEquals("graph failed to load: text: model file name invalid: $name", error.message)
            }
        }
    }

    @Test
    fun composedRuntimeRefusesAPackageThatNeedsMoreMemoryThanTheDeviceHas() = runTest {
        val modelPackage = speechPackage("articulino", Source(sourceType = SourceType.Filesystem, ref = "/nonexistent"))
            .copy(limits = Limits(memBytes = 2000))
        val refusal = NeuralSpeechAvailability(false, "insufficient memory: package needs 2000 bytes, device has 1000 bytes")
        val small = OnnxNeuralSpeechRuntime(context, OnnxNeuralSpeechRuntimeOptions(deviceMemoryBytes = { 1000L }))
        assertEquals(refusal, small.availability(modelPackage))
        assertEquals(refusal, small.prepare(modelPackage))
        try {
            small.synthesize(NeuralSpeechSynthesisInput(modelPackage, "a", "de", "v")).toList()
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
            assertEquals(refusal.reason, error.message)
        }

        val large = OnnxNeuralSpeechRuntime(context, OnnxNeuralSpeechRuntimeOptions(deviceMemoryBytes = { 2000L }))
        val enough = large.availability(modelPackage)
        assertFalse(enough.reason.orEmpty(), enough.reason.orEmpty().startsWith("insufficient memory"))
    }

    @Test
    fun composedRuntimeRefusesAnUnknownPipeline() = runTest {
        val modelPackage = speechPackage("fixture", Source(sourceType = SourceType.Filesystem, ref = "/nonexistent"))
        val availability = OnnxNeuralSpeechRuntime(context).availability(modelPackage)
        assertFalse(availability.available)
        assertEquals("unsupported pipeline 'fixture'", availability.reason)
    }

    @Test
    fun composedRuntimeReportsTheResolverMessage() = runTest {
        val modelPackage = speechPackage("articulino", Source(sourceType = SourceType.Registry))
        val runtime = OnnxNeuralSpeechRuntime(context)
        for (availability in listOf(runtime.availability(modelPackage), runtime.prepare(modelPackage))) {
            assertFalse(availability.available)
            assertTrue(availability.reason.orEmpty(), availability.reason.orEmpty().contains("model source unavailable"))
        }
    }

    @Test
    fun composedRuntimeReportsAMissingSource() = runTest {
        val availability = OnnxNeuralSpeechRuntime(context).availability(speechPackage("articulino", null))
        assertFalse(availability.available)
        assertEquals("model source unavailable: no model source was configured.", availability.reason)
    }

    private fun speechPackage(pipeline: String, source: Source?) = ModelPackage(
        id = "t",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = source,
        speech = SpeechModelPackage(
            pipeline = pipeline,
            sampleRate = 24000,
            graphs = mapOf("text" to "text.onnx"),
            frontend = SpeechFrontend(kind = FrontendKind.Grapheme),
            voices = emptyList(),
        ),
    )
}
