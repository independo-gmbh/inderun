package app.independo.inderun.demo

import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.ExecutionProvenanceAttempt
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.core.ArtifactChunk
import app.independo.inderun.core.StreamRun
import app.independo.inderun.sdk.SpeakOptions
import app.independo.inderun.sdk.SpeechPlayback
import app.independo.inderun.sdk.SpeechVoiceInfo
import app.independo.inderun.sdk.generated.IndeRunApi
import app.independo.inderun.sdk.speak
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.ByteArrayInputStream
import java.security.MessageDigest

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class VoicesLabViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @get:Rule
    val temp = TemporaryFolder()

    private val weights = "weights".toByteArray()
    private val voice = "voice".toByteArray()

    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun catalog() = """
        {"entries":[
          {"id":"m1","family":"articulino","pipeline":"articulino","version":"1","variant":"onnx-int8",
           "license":{"spdx":"Apache-2.0","restrictions":"none"},
           "review":{"status":"benchmark_only"},
           "runtime":{"format":"onnx","platforms":["android"],"minOsVersion":null},
           "sampleRate":24000,
           "speech":{"pipeline":"articulino","sampleRate":24000,"channels":1,"graphs":{"text":"text.onnx"},
                     "frontend":{"kind":"grapheme","assets":{"config":"config.json"}}},
           "files":[{"role":"graph:text","path":"text.onnx","url":"https://huggingface.co/x/text.onnx","sha256":"${sha(weights)}","bytes":${weights.size}}],
           "voices":[{"id":"v1","name":"V1","locales":["de-DE"],"gender":"female",
                      "file":{"path":"voices/v1.safetensors","url":"https://huggingface.co/x/v1","sha256":"${sha(voice)}","bytes":${voice.size}},
                      "license":{"spdx":"LicenseRef-Demo","restrictions":"demo"}}]},
          {"id":"core","family":"articulino","pipeline":"articulino","version":"1","variant":"coreai",
           "license":{"spdx":"Apache-2.0"},"review":{"status":"manual_install","notes":"install by hand"},
           "runtime":{"format":"coreai","platforms":["ios"],"minOsVersion":"27.0"},"sampleRate":24000,
           "speech":{"pipeline":"articulino","sampleRate":24000,"channels":1,"graphs":{"text":"a#text"},
                     "frontend":{"kind":"grapheme","assets":{"config":"config.json"}}}}
        ]}
    """.trimIndent()

    private class FakeRuntime(
        val speakScript: suspend (SpeakOptions, CoroutineScope) -> SpeechPlayback = { _, _ -> error("not scripted") },
    ) : VoicesLabRuntime {
        val installs = mutableListOf<List<String>>()
        val speakCalls = mutableListOf<SpeakOptions>()
        override fun install(entries: List<CatalogEntry>) {
            installs += entries.map { it.id }
        }
        override suspend fun listVoices(locale: String?): List<SpeechVoiceInfo> = emptyList()
        override suspend fun speak(options: SpeakOptions, scope: CoroutineScope): SpeechPlayback {
            speakCalls += options
            return speakScript(options, scope)
        }
        override suspend fun warm(entry: CatalogEntry, scope: CoroutineScope): List<String> = emptyList()
    }

    private class Harness(val reads: IntArray, val requests: MutableList<String>, val runtime: FakeRuntime, val viewModel: VoicesLabViewModel)

    private fun harness(): Harness {
        val reads = intArrayOf(0)
        val requests = mutableListOf<String>()
        val transport = NeuralTransport { url ->
            requests += url
            TransportResponse(200, ByteArrayInputStream(if (url.endsWith("text.onnx")) weights else voice))
        }
        val runtime = FakeRuntime()
        val viewModel = VoicesLabViewModel(
            catalogSource = {
                reads[0]++
                catalog()
            },
            corpusSource = { null },
            downloader = DemoNeuralModelDownloader(temp.root, transport, io = mainDispatcherRule.dispatcher),
            runtime = runtime,
            dispatcher = mainDispatcherRule.dispatcher,
        )
        return Harness(reads, requests, runtime, viewModel)
    }

    @Test
    fun lab_off_reads_no_catalog_and_registers_nothing() = runTest {
        val h = harness()
        advanceUntilIdle()

        assertEquals(0, h.reads[0])
        assertTrue(h.runtime.installs.isEmpty())
        assertEquals(0, temp.root.list()!!.size)
    }

    @Test
    fun start_reads_the_catalog_read_only_and_marks_core_ai_unavailable() = runTest {
        val h = harness()
        h.viewModel.start()
        h.viewModel.start()
        advanceUntilIdle()

        val state = h.viewModel.state.value
        assertEquals(1, h.reads[0])
        assertEquals(listOf("m1"), state.installable.map { it.id })
        assertEquals("install by hand", state.unavailable.single().second)
        assertEquals(listOf(emptyList<String>()), h.runtime.installs)
        assertTrue(h.requests.isEmpty())
        assertEquals(0, temp.root.list()!!.size)
    }

    @Test
    fun declined_consent_requests_nothing_and_accepted_consent_registers_the_model() = runTest {
        val h = harness()
        h.viewModel.start()
        advanceUntilIdle()
        h.viewModel.selectModel("m1")

        h.viewModel.downloadOrWarm()
        advanceUntilIdle()
        assertNotNull(h.viewModel.state.value.pendingConsent)
        h.viewModel.answerConsent(false)
        advanceUntilIdle()
        assertTrue(h.requests.isEmpty())
        assertNull(h.viewModel.state.value.pendingConsent)

        h.viewModel.downloadOrWarm()
        advanceUntilIdle()
        h.viewModel.answerConsent(true)
        advanceUntilIdle()

        assertEquals(2, h.requests.size)
        assertTrue("m1" in h.viewModel.state.value.installedIds)
        assertEquals(listOf("m1"), h.runtime.installs.last())
        assertFalse(h.viewModel.state.value.isDownloading)
    }

    @Test
    fun a_failed_download_reports_the_error_and_registers_nothing() = runTest {
        val h = Harness(
            intArrayOf(0),
            mutableListOf(),
            FakeRuntime(),
            run {
                VoicesLabViewModel(
                    catalogSource = { catalog() },
                    corpusSource = { null },
                    downloader = DemoNeuralModelDownloader(temp.root, { TransportResponse(500, null) }, io = mainDispatcherRule.dispatcher),
                    runtime = FakeRuntime(),
                    dispatcher = mainDispatcherRule.dispatcher,
                )
            },
        )
        h.viewModel.start()
        advanceUntilIdle()
        h.viewModel.selectModel("m1")
        h.viewModel.downloadOrWarm()
        advanceUntilIdle()
        h.viewModel.answerConsent(true)
        advanceUntilIdle()

        assertEquals("download failed (HTTP 500): text.onnx", h.viewModel.state.value.status)
        assertTrue(h.viewModel.state.value.installedIds.isEmpty())
    }

    @Test
    fun status_card_names_the_provider_that_spoke_and_the_fallback() {
        val entry = NeuralCatalogParser.parse(catalog()).first()
        val neural = neuralProviderId("m1")
        val spoke = SpokenSummary(neural, null, "V1", "de-DE", "local", "stop", 120)
        val (_, spokeRows) = statusCard(spoke, askedNeural = true, entry = entry, requestedLocale = "de-DE", chosenVoiceName = "V1")
        assertEquals(neural, spokeRows.toMap()["Provider"])
        assertEquals("m1 (onnx-int8)", spokeRows.toMap()["Model"])
        assertEquals("onnxruntime-android (CPU)", spokeRows.toMap()["Runtime"])

        val fell = SpokenSummary("android_system_speech", "failed, unavailable", null, "de-DE", "local", "stop", null)
        val (line, rows) = statusCard(fell, askedNeural = true, entry = entry, requestedLocale = "de-DE", chosenVoiceName = "V1")
        val map = rows.toMap()
        assertEquals("android_system_speech", map["Provider"])
        assertEquals("fell back to OS voice (neural: failed, unavailable)", map["Result"])
        assertNull(map["Model"])
        assertNull(map["Runtime"])
        assertEquals("automatic", map["Voice"])
        assertEquals("fell back to OS voice (neural: failed, unavailable): stop", line)

        val control = statusCard(fell.copy(failedNeuralAttempt = null), askedNeural = false, entry = null, requestedLocale = "de-DE", chosenVoiceName = null).second.toMap()
        assertEquals("OS TTS (control)", control["Model"])
        assertNull(control["Result"])
    }

    /** Puts a verified install of m1 on disk, as a previous download would have. */
    private fun preinstall() {
        val dir = java.io.File(temp.root, "voices-lab/m1/1")
        java.io.File(dir, "voices").mkdirs()
        java.io.File(dir, "text.onnx").writeBytes(weights)
        java.io.File(dir, "voices/v1.safetensors").writeBytes(voice)
    }

    /** An engine that settles one speech run, completed by [providerId] after the [failedFirst] attempts. */
    private fun speakingAs(
        providerId: String,
        failedFirst: List<ExecutionProvenanceAttempt> = emptyList(),
    ): suspend (SpeakOptions, CoroutineScope) -> SpeechPlayback = { options, scope ->
        object : IndeRunApi {
            override suspend fun prepare(request: PrepareRequest): StreamRun = error("not scripted")
            override suspend fun stream(request: TaskRequest): StreamRun = StreamRun(
                handle = StreamRunHandle(providerId = providerId, runId = "run_x", schemaVersion = SchemaVersion.V1_0, startedAt = 0.0),
                events = flowOf(
                    StreamEvent(
                        payload = Payload(
                            outcome = Outcome.Completed,
                            finishReason = FinishReason.STOP,
                            provenance = ExecutionProvenance(
                                attemptCount = failedFirst.size + 1L,
                                attempts = failedFirst + ExecutionProvenanceAttempt(outcome = AttemptOutcome.Succeeded, providerId = providerId),
                                fallbackOccurred = failedFirst.isNotEmpty(),
                                locality = Locality.OnDevice,
                                modelProfile = options.model ?: "auto",
                                providerId = providerId,
                                routeRejections = emptyList(),
                            ),
                            runId = "run_x",
                        ),
                        runId = "run_x",
                        schemaVersion = SchemaVersion.V1_0,
                        sequence = 0,
                        timestamp = 0.0,
                        type = "terminal",
                    ),
                ),
                onCancel = {},
            )
            override suspend fun run(request: TaskRequest): TaskResult = error("not scripted")
            override suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> = emptyList()
            override suspend fun readArtifact(request: ArtifactReadRequest): ArtifactChunk = error("not scripted")
            override suspend fun disposeArtifact(artifact: MediaArtifact) = error("not scripted")

            override suspend fun close() = error("not scripted")
        }.speak(options, scope)
    }

    private fun installedHarness(runtime: FakeRuntime): VoicesLabViewModel {
        preinstall()
        return VoicesLabViewModel(
            catalogSource = { catalog() },
            corpusSource = { null },
            downloader = DemoNeuralModelDownloader(temp.root, { error("no request expected") }, io = mainDispatcherRule.dispatcher),
            runtime = runtime,
            dispatcher = mainDispatcherRule.dispatcher,
        )
    }

    @Test
    fun a_b_speaks_the_neural_profile_then_the_control() = runTest {
        val runtime = FakeRuntime(speakingAs(neuralProviderId("m1")))
        val viewModel = installedHarness(runtime)
        viewModel.start()
        advanceUntilIdle()
        assertTrue("m1" in viewModel.state.value.installedIds)
        viewModel.selectModel("m1")

        viewModel.compareAB()
        advanceUntilIdle()

        assertEquals(listOf("voices-lab:m1", "voices-lab:control"), runtime.speakCalls.map { it.model })
    }

    @Test
    fun a_b_stops_after_a_neural_fallback_and_says_the_comparison_is_invalid() = runTest {
        val failedNeural = ExecutionProvenanceAttempt(
            errorClass = IndeRunErrorClass.Unavailable,
            outcome = AttemptOutcome.Failed,
            providerId = neuralProviderId("m1"),
        )
        val runtime = FakeRuntime(speakingAs("android_system_speech", failedFirst = listOf(failedNeural)))
        val viewModel = installedHarness(runtime)
        viewModel.start()
        advanceUntilIdle()
        viewModel.selectModel("m1")

        viewModel.compareAB()
        advanceUntilIdle()

        // OS speech answered the neural leg, so playing the OS control would compare OS with OS.
        assertEquals(listOf("voices-lab:m1"), runtime.speakCalls.map { it.model })
        val state = viewModel.state.value
        assertEquals(
            "comparison invalid: neural fell back to android_system_speech (neural: failed, Unavailable); the OS control was skipped",
            state.status,
        )
        assertEquals("fell back to OS voice (neural: failed, Unavailable)", state.card.toMap()["Result"])
        assertFalse(state.isSpeaking)
    }

    @Test
    fun a_neural_request_answered_by_the_os_voice_shows_the_fallback_card() = runTest {
        val runtime = FakeRuntime(speakingAs("android_system_speech"))
        val viewModel = installedHarness(runtime)
        viewModel.start()
        advanceUntilIdle()
        viewModel.selectModel("m1")

        viewModel.speakSelected()
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals("fell back to OS voice: stop", state.status)
        assertEquals("fell back to OS voice", state.card.toMap()["Result"])
        assertEquals("android_system_speech", state.card.toMap()["Provider"])
    }

    @Test
    fun a_stray_exception_from_speak_becomes_a_status_not_a_crash() = runTest {
        val viewModel = installedHarness(FakeRuntime { _, _ -> throw IllegalStateException("boom") })
        viewModel.start()
        advanceUntilIdle()

        viewModel.speakSelected() // control is the default when nothing is selected
        viewModel.selectModel(VoicesLabViewModel.CONTROL)
        viewModel.speakSelected()
        advanceUntilIdle()

        assertEquals("failed: boom", viewModel.state.value.status)
        assertFalse(viewModel.state.value.isSpeaking)
    }

    /** Advances the test scheduler until [done] holds; the real IO dispatcher finishes in between. */
    private suspend fun kotlinx.coroutines.test.TestScope.awaitUntil(done: () -> Boolean) {
        for (attempt in 0 until 500) {
            advanceUntilIdle()
            if (done()) return
            Thread.sleep(10)
        }
        fail("condition not reached")
    }

    private class Blocked(val viewModel: VoicesLabViewModel, val requests: MutableList<String>, val reached: java.util.concurrent.CountDownLatch, val release: java.util.concurrent.CountDownLatch)

    /** A lab whose text.onnx download stalls after 3 bytes until [Blocked.release] (or until the response is closed). */
    private fun stalledLab(): Blocked {
        val reached = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val requests = java.util.Collections.synchronizedList(mutableListOf<String>())
        val transport = NeuralTransport { url ->
            requests += url
            if (url.endsWith("text.onnx")) {
                TransportResponse(200, BlockingStream(weights, reached, release)) { release.countDown() }
            } else {
                TransportResponse(200, ByteArrayInputStream(voice))
            }
        }
        val viewModel = VoicesLabViewModel(
            catalogSource = { catalog() },
            corpusSource = { null },
            downloader = DemoNeuralModelDownloader(temp.root, transport),
            runtime = FakeRuntime(),
            dispatcher = mainDispatcherRule.dispatcher,
        )
        return Blocked(viewModel, requests, reached, release)
    }

    private suspend fun kotlinx.coroutines.test.TestScope.startDownload(lab: Blocked) {
        lab.viewModel.start()
        awaitUntil { lab.viewModel.state.value.installable.isNotEmpty() }
        lab.viewModel.selectModel("m1")
        lab.viewModel.downloadOrWarm()
        advanceUntilIdle()
        lab.viewModel.answerConsent(true)
        advanceUntilIdle()
        assertTrue(lab.reached.await(5, java.util.concurrent.TimeUnit.SECONDS))
    }

    private fun assertCancelledCleanly(lab: Blocked) {
        val state = lab.viewModel.state.value
        assertFalse(state.isDownloading)
        assertTrue(state.status!!.startsWith("Download cancelled"))
        assertTrue(state.installedIds.isEmpty())
        val dir = java.io.File(temp.root, "voices-lab/m1/1")
        assertFalse(java.io.File(dir, "text.onnx").exists())
        assertFalse(java.io.File(dir, "text.onnx.part").exists())
        assertEquals(1, lab.requests.size)
    }

    @Test
    fun cancelling_a_download_removes_the_partial_file_and_says_so() = runTest {
        val lab = stalledLab()
        startDownload(lab)

        lab.viewModel.cancelDownload()
        awaitUntil { !lab.viewModel.state.value.isDownloading }

        assertCancelledCleanly(lab)
    }

    @Test
    fun switching_the_lab_off_cancels_the_download() = runTest {
        val lab = stalledLab()
        startDownload(lab)

        lab.viewModel.shutdown()
        awaitUntil { !lab.viewModel.state.value.isDownloading }

        assertCancelledCleanly(lab)
        assertFalse(lab.viewModel.state.value.started)
    }

    @Test
    fun a_configuration_change_keeps_the_download_running() = runTest {
        val lab = stalledLab()
        startDownload(lab)

        // A rotation recomposes the screen, which calls start() again; nothing calls shutdown().
        lab.viewModel.start()
        advanceUntilIdle()
        assertTrue(lab.viewModel.state.value.isDownloading)
        lab.release.countDown()
        awaitUntil { lab.viewModel.state.value.installedIds.isNotEmpty() || lab.viewModel.state.value.status?.startsWith("download failed") == true }

        // The stalled stream ends with an IOException after release, so the point is that it was not cancelled.
        assertFalse(lab.viewModel.state.value.status!!.startsWith("Download cancelled"))
    }

    @Test
    fun shutdown_during_the_installed_check_registers_nothing() = runTest {
        val h = harness()
        h.viewModel.start()
        h.viewModel.shutdown()
        advanceUntilIdle()

        assertTrue(h.runtime.installs.isEmpty())
        assertFalse(h.viewModel.state.value.isChecking)
    }

    /** Delivers [first], then blocks until the response is closed, as a stalled socket does. */
    private class BlockingStream(
        private val first: ByteArray,
        private val reached: java.util.concurrent.CountDownLatch,
        private val closed: java.util.concurrent.CountDownLatch,
    ) : java.io.InputStream() {
        private var delivered = false
        override fun read(): Int = error("unused")
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (!delivered) {
                delivered = true
                first.copyInto(b, off)
                return first.size
            }
            reached.countDown()
            closed.await()
            throw java.io.IOException("stream closed")
        }
    }
}
