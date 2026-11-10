package app.independo.inderun.sdk

import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.providers.systemspeech.AndroidSpeechEngine
import app.independo.inderun.providers.systemspeech.AndroidSpeechReadiness
import app.independo.inderun.providers.systemspeech.AndroidSpeechVoice
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The Android system speech provider through the real engine and the real route planner. */
@RunWith(RobolectricTestRunner::class)
class AndroidSystemSpeechEngineTest {
    private class FakeEngine(
        private val voiceList: List<AndroidSpeechVoice>,
        private val holds: Boolean = false,
        private val failure: Throwable? = null,
    ) : AndroidSpeechEngine {
        @Volatile var selected: AndroidSpeechVoice? = null

        @Volatile var spoken = 0

        @Volatile var stopped = false

        val started = CompletableDeferred<Unit>()

        override suspend fun readiness() = AndroidSpeechReadiness.Ready

        override suspend fun voices() = voiceList

        override suspend fun select(locale: String, voice: AndroidSpeechVoice?): Boolean {
            selected = voice
            return true
        }

        override suspend fun speak(text: String): Double? {
            spoken += 1
            started.complete(Unit)
            failure?.let { throw it }
            if (holds) {
                try {
                    CompletableDeferred<Unit>().await()
                } catch (cancelled: CancellationException) {
                    stopped = true
                    throw cancelled
                }
            }
            return 500.0
        }

        override suspend fun synthesize(text: String, maxBytes: Long) = ByteArray(0)

        override fun close() = Unit
    }

    private val local = AndroidSpeechVoice("local", "de-DE", networkRequired = false)
    private val network = AndroidSpeechVoice("network", "de-DE", networkRequired = true)
    private val scope = CoroutineScope(Dispatchers.Default)

    private fun inderun(engine: FakeEngine, also: FakeStreamProvider? = null): IndeRun {
        val registry = ProviderRegistry().apply {
            register(AndroidSystemSpeechProvider(AndroidSystemSpeechProvider.DEFAULT_ID, engine))
            also?.let { register(it) }
        }
        return IndeRun(registry, conformanceHostServices())
    }

    private fun options(privacy: Privacy? = null) = SpeakOptions(
        "Hallo",
        locale = "de-DE",
        execution = privacy?.let { SpeechExecutionOptions(privacy = it) },
    )

    @Test
    fun routingBindsTheOnDeviceVoiceAndReportsItsLocality() = runBlocking {
        val engine = FakeEngine(listOf(network, local))

        val ending = inderun(engine).speak(options(), scope).result.await()

        assertEquals(local, engine.selected)
        assertEquals(FinishReason.STOP, ending.finishReason)
        assertEquals(500.0, ending.timing?.durationMs)
        assertEquals(Locality.OnDevice, ending.provenance?.locality)
    }

    @Test
    fun anEngineThatListsNoVoicesIsNotReportedAsOnDevice() = runBlocking {
        val engine = FakeEngine(emptyList())

        val ending = inderun(engine).speak(options(), scope).result.await()

        assertEquals(FinishReason.STOP, ending.finishReason)
        assertEquals(Locality.Unknown, ending.provenance?.locality)
    }

    @Test
    fun aNetworkVoiceIsNotReportedAsOnDevice() = runBlocking {
        val engine = FakeEngine(listOf(network))

        val ending = inderun(engine).speak(options(), scope).result.await()

        assertEquals(network, engine.selected)
        assertEquals(Locality.Unknown, ending.provenance?.locality)
    }

    @Test
    fun localRequiredRefusesANetworkVoiceBeforeAnyAudio() = runBlocking {
        val engine = FakeEngine(listOf(network))

        try {
            inderun(engine).speak(options(Privacy.LocalRequired), scope).result.await()
            fail("expected a routing refusal")
        } catch (error: IndeRunException) {
            assertEquals(Code.PrivacyConstraint, error.provenance?.routeRejections?.single()?.codes?.single())
        }
        assertEquals(0, engine.spoken)
    }

    @Test
    fun cancelStopsTheAudioAndEndsTheRunOnce() = runBlocking {
        val engine = FakeEngine(listOf(local), holds = true)

        val playback = inderun(engine).speak(options(), scope)
        engine.started.await()
        playback.cancel("stop")
        playback.cancel("again")
        val ending = playback.result.await()
        delay(50)

        assertEquals(FinishReason.CANCELLED, ending.finishReason)
        assertEquals(AttemptOutcome.Cancelled, ending.provenance?.attempts?.single()?.outcome)
        assertTrue("the provider must stop the audio", engine.stopped)
    }

    @Test
    fun aFailureAfterCommitDoesNotRestartSpeechOnAnotherProvider() = runBlocking {
        val engine = FakeEngine(listOf(local), failure = createUnavailable("audio failed"))
        val fallback = FakeStreamProvider("z_fallback", task = TaskKind.TEXT_TO_SPEECH)

        try {
            inderun(engine, fallback).speak(options(), scope).result.await()
            fail("expected the run to fail")
        } catch (error: IndeRunException) {
            assertEquals(1, error.provenance?.attempts?.size)
        }
        assertEquals(0, fallback.callCount)
    }
}
