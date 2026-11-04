package app.independo.inderun.providers.onnx

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidOnnxRuntimeProviderTest {

    @Test
    fun describeReflectsStandardOnnxDescriptor() {
        val provider = providerWith(runtime = createFixtureOnnxRuntime())

        val descriptor = provider.describe()

        assertTrue(descriptor.supports.run)
        assertFalse(descriptor.supports.streaming)
        assertEquals(listOf("text_to_text"), descriptor.tasks)
        assertEquals(false, descriptor.privacy?.dataLeavesDevice)
    }

    @Test
    fun capabilitiesRejectMalformedModelPackage() = runTest {
        val provider = providerWith(
            modelPackage = modelPackage(id = "  "),
            runtime = createFixtureOnnxRuntime(),
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertFalse(capabilities.available)
        assertTrue(capabilities.reason.orEmpty().contains("model package malformed"))
    }

    @Test
    fun capabilitiesDeferRegistrySource() = runTest {
        val provider = providerWith(
            modelPackage = modelPackage(sourceType = SourceType.Registry),
            runtime = createFixtureOnnxRuntime(),
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertFalse(capabilities.available)
        assertTrue(capabilities.reason.orEmpty().contains("deferred"))
    }

    private class CountingRuntime(
        private val loadResult: AndroidOnnxRuntimeAvailability = AndroidOnnxRuntimeAvailability(available = true),
    ) : AndroidOnnxGenAiRuntime by createFixtureOnnxRuntime() {
        var loads = 0

        override suspend fun prepare(modelPackage: ModelPackage): AndroidOnnxRuntimeAvailability {
            loads += 1
            return loadResult
        }
    }

    @Test
    fun aCapabilityCheckNeverLoadsTheModelAndReportsItCold() = runTest {
        val runtime = CountingRuntime()
        val provider = providerWith(modelPackage = modelPackage(sourceType = SourceType.Filesystem), runtime = runtime)

        val capabilities = provider.capabilities(fakeHostServices())

        assertEquals(0, runtime.loads)
        assertTrue(capabilities.available)
        assertEquals(ProviderReadiness.Cold, capabilities.taskCapabilities?.single()?.readiness)
    }

    @Test
    fun prepareLoadsOnceAndThenReportsReady() = runTest {
        val runtime = CountingRuntime()
        val provider = providerWith(modelPackage = modelPackage(sourceType = SourceType.Filesystem), runtime = runtime)
        val context = ProviderPrepareContext("run_1", fakeHostServices(), "text_to_text")

        provider.prepare(context).toList()
        provider.prepare(context).toList()

        assertEquals(1, runtime.loads)
        assertEquals(null, provider.capabilities(fakeHostServices()).taskCapabilities)
    }

    @Test
    fun aFailedLoadIsRememberedSoRoutingStopsChoosingTheProvider() = runTest {
        val runtime = CountingRuntime(AndroidOnnxRuntimeAvailability(available = false, reason = "model corrupt"))
        val provider = providerWith(modelPackage = modelPackage(sourceType = SourceType.Filesystem), runtime = runtime)
        val context = ProviderPrepareContext("run_1", fakeHostServices(), "text_to_text")

        try {
            provider.prepare(context).toList()
            fail("Expected the load to fail.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }

        val capabilities = provider.capabilities(fakeHostServices())
        assertFalse(capabilities.available)
        assertEquals("model corrupt", capabilities.reason)
    }

    @Test
    fun capabilitiesAcceptFilesystemSource() = runTest {
        val provider = providerWith(
            modelPackage = modelPackage(sourceType = SourceType.Filesystem),
            runtime = createFixtureOnnxRuntime(),
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertTrue(capabilities.available)
    }

    @Test
    fun capabilitiesRejectUnsupportedTask() = runTest {
        val provider = providerWith(
            modelPackage = modelPackage(tasks = listOf("image_to_text")),
            runtime = createFixtureOnnxRuntime(),
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertFalse(capabilities.available)
        assertTrue(capabilities.reason.orEmpty().contains("unsupported task"))
    }

    @Test
    fun runReturnsCanonicalResultViaFixture() = runTest {
        val provider = providerWith(
            runtime = createFixtureOnnxRuntime(
                options = FixtureOnnxRuntimeOptions(
                    respond = { AndroidOnnxGenerationOutput(text = "Generated response") },
                ),
            ),
        )

        val result = provider.run(
            request = taskRequest(prompt = "Hello"),
            context = RunContext("run_123", fakeHostServices()),
        )

        assertEquals("Generated response", result.output.text)
        assertEquals("run_123", result.runId)
    }

    @Test
    fun runMapsUnavailableCapabilityToCapabilityMismatch() = runTest {
        val provider = providerWith(
            runtime = createFixtureOnnxRuntime(
                options = FixtureOnnxRuntimeOptions(
                    availability = AndroidOnnxRuntimeAvailability(available = false, reason = "not ready"),
                ),
            ),
        )

        try {
            provider.run(taskRequest(prompt = "Hello"), RunContext("run_123", fakeHostServices()))
            fail("Expected CapabilityMismatch when the runtime reports unavailable.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
    }

    @Test
    fun runMapsOnnxRuntimeErrorKindsToErrorClasses() = runTest {
        val cases = mapOf(
            OnnxRuntimeErrorKind.CAPABILITY to IndeRunErrorClass.CapabilityMismatch,
            OnnxRuntimeErrorKind.UNAVAILABLE to IndeRunErrorClass.Unavailable,
            OnnxRuntimeErrorKind.TIMEOUT to IndeRunErrorClass.Timeout,
            OnnxRuntimeErrorKind.INTERNAL_FAILURE to IndeRunErrorClass.Internal,
        )

        for ((kind, expected) in cases) {
            val provider = providerWith(
                runtime = createFixtureOnnxRuntime(
                    options = FixtureOnnxRuntimeOptions(
                        failWith = OnnxRuntimeError(kind = kind, message = "boom"),
                    ),
                ),
            )

            try {
                provider.run(taskRequest(prompt = "Hello"), RunContext("run_123", fakeHostServices()))
                fail("Expected $expected for kind $kind.")
            } catch (error: IndeRunException) {
                assertEquals(expected, error.errorClass)
            }
        }
    }

    @Test
    fun modelPackageValidationRejectsUrlUserinfoInSourceRef() {
        val issues = getModelPackageValidationIssues(
            modelPackage(ref = "https://user:pass@example.com/model"),
        )

        assertTrue(issues.any { it.path == "/source/ref" })
    }

    @Test
    fun modelPackageValidationAllowsPlainSourceRef() {
        val issues = getModelPackageValidationIssues(modelPackage(ref = "models/phi-3"))

        assertTrue(issues.none { it.path == "/source/ref" })
    }

    @Test
    fun modelPackageValidationRequiresSpeechForTextToSpeech() {
        val issues = getModelPackageValidationIssues(modelPackage().copy(tasks = listOf("text_to_speech")))

        assertTrue(issues.any { it.path == "/speech" })
    }

    @Test
    fun modelPackageValidationRejectsDuplicateSpeechVoiceIds() {
        val voice = SpeechModelVoice(id = "v", name = "V", locales = listOf("de-DE"), file = "v.bin")
        val speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "a.onnx"),
            voices = listOf(voice, voice),
        )

        val issues = getModelPackageValidationIssues(
            modelPackage().copy(tasks = listOf("text_to_speech"), speech = speech),
        )

        assertTrue(issues.any { it.path == "/speech/voices" })
    }

    private fun speechPackage(
        sampleRate: Long = 24000,
        graphs: Map<String, String> = mapOf("acoustic" to "a.onnx"),
        voices: List<SpeechModelVoice>,
    ) = modelPackage().copy(
        tasks = listOf("text_to_speech"),
        speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = sampleRate,
            graphs = graphs,
            voices = voices,
        ),
    )

    private fun speechVoice(locales: List<String>) = SpeechModelVoice(id = "v", name = "V", locales = locales, file = "v.bin")

    @Test
    fun modelPackageValidationRejectsStructurallyEmptySpeech() {
        val issues = getModelPackageValidationIssues(
            speechPackage(sampleRate = 0, graphs = emptyMap(), voices = emptyList()),
        )

        assertEquals(
            listOf("/speech/sampleRate", "/speech/graphs", "/speech/voices"),
            issues.map { it.path },
        )
        assertEquals(
            listOf("must be >= 1", "must list at least one graph", "must list at least one voice"),
            issues.map { it.message },
        )
    }

    @Test
    fun modelPackageValidationRejectsMalformedVoiceLocales() {
        val emptyLocales = getModelPackageValidationIssues(speechPackage(voices = listOf(speechVoice(emptyList()))))
        assertEquals(listOf("/speech/voices/0/locales"), emptyLocales.map { it.path })
        assertEquals(listOf("must list at least one locale"), emptyLocales.map { it.message })

        val malformed = listOf("de_DE", "-de-DE", "de-DE!", "", "de-DE\n")
        val badTags = getModelPackageValidationIssues(speechPackage(voices = listOf(speechVoice(malformed))))
        assertEquals(malformed.indices.map { "/speech/voices/0/locales/$it" }, badTags.map { it.path })
        assertEquals(malformed.map { "must be a hyphenated BCP 47 tag" }, badTags.map { it.message })
    }

    @Test
    fun modelPackageValidationAcceptsAWellFormedSpeechPackage() {
        val issues = getModelPackageValidationIssues(
            speechPackage(voices = listOf(speechVoice(listOf("de-DE", "en-US")))),
        )

        assertEquals(emptyList<ModelPackageValidationIssue>(), issues)
    }

    @Test
    fun cancellationPropagatesRawWithoutNormalization() = runTest {
        val provider = providerWith(
            runtime = createFixtureOnnxRuntime(options = FixtureOnnxRuntimeOptions(delayMs = 10_000)),
        )

        val job = async {
            provider.run(taskRequest(prompt = "Hello"), RunContext("run_123", fakeHostServices()))
        }
        job.cancel()

        try {
            job.await()
            fail("Expected cancellation to propagate.")
        } catch (error: CancellationException) {
            // expected: raw cancellation, not an IndeRunException
        }
    }

    @Test
    fun runTimesOutWhenGenerationExceedsDeadline() = runTest {
        val provider = providerWith(
            runtime = createFixtureOnnxRuntime(options = FixtureOnnxRuntimeOptions(delayMs = 5_000)),
            timeoutMs = 10,
        )

        try {
            provider.run(taskRequest(prompt = "Hello"), RunContext("run_123", fakeHostServices()))
            fail("Expected a Timeout error.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Timeout, error.errorClass)
        }
    }

    private fun providerWith(
        modelPackage: ModelPackage = modelPackage(),
        runtime: AndroidOnnxGenAiRuntime,
        timeoutMs: Long? = null,
    ): AndroidOnnxRuntimeProvider = AndroidOnnxRuntimeProvider(
        modelPackage = modelPackage,
        runtime = runtime,
        timeoutMs = timeoutMs,
    )

    private fun modelPackage(
        id: String = "phi-3-mini",
        sourceType: SourceType = SourceType.Bundled,
        ref: String? = "models/phi-3",
        tasks: List<String>? = null,
    ): ModelPackage = ModelPackage(
        id = id,
        format = Format.Onnx,
        source = Source(sourceType = sourceType, ref = ref),
        tasks = tasks,
    )

    private fun taskRequest(prompt: String): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = prompt,
        task = TaskRequestTask(),
        constraints = TaskRequestConstraints(privacy = Privacy.LocalRequired),
    )

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
}
