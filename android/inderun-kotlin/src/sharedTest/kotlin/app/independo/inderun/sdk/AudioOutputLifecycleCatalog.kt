package app.independo.inderun.sdk

import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioOutputService
import app.independo.inderun.core.IndeRunException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The audio output catalog (`contracts/fixtures/host/audio-output-lifecycle.json`, ADR 021) as
 * code: one handler per case id, and a check that compares what a handler observed with the
 * case's `expect` data. Shared by the JVM run against the fixture service and the instrumented
 * run against the real `AudioTrack` service. Mirrors `audio-output.conformance.test.ts`.
 */

/**
 * A service under test and the clock its elapsed times are read on (the fixture's virtual clock,
 * or wall time for a real service).
 */
internal class AudioOutputTarget(val service: AudioOutputService, val now: () -> Double)

/** What a handler saw; every field is optional because each case observes a few. */
internal class AudioOutputObservation(
    val firstAudioDefinedAfterOpen: Boolean? = null,
    val firstAudioDefinedAfterWrites: Boolean? = null,
    val firstAudioMs: Double? = null,
    val drainElapsedMs: Double? = null,
    val stopThrew: Boolean? = null,
    val stopCalls: Int? = null,
    val writeSettledAfterStopMs: Double? = null,
    val writeAfterStopElapsedMs: Double? = null,
    val writeAfterStopThrew: Boolean? = null,
    val drainAfterStopElapsedMs: Double? = null,
    val drainAfterStopThrew: Boolean? = null,
    val stoppedDrainElapsedMs: Double? = null,
    val otherDrainElapsedMs: Double? = null,
    val openRejection: IndeRunException? = null,
)

private val catalogFormat = AudioOutputFormat(sampleRate = 24000)

/** 440 Hz at -14 dBFS. */
private fun tone(ms: Int, sampleRate: Int = catalogFormat.sampleRate): ShortArray {
    val frames = (sampleRate.toDouble() * ms / 1000).roundToInt()
    val amplitude = 32767 * 10.0.pow(-14.0 / 20)
    return ShortArray(frames) { index ->
        (amplitude * sin(2 * PI * 440 * index / sampleRate)).roundToInt().toShort()
    }
}

/** Waits `ms` on the coroutine clock (virtual under `runTest`; the fixture's own clock is separate). */
private suspend fun settle(ms: Int) = delay(ms.toLong())

/** Runs `block`, failing the case rather than hanging when it does not settle within `ms`. */
private suspend fun <T> bounded(ms: Int, label: String, block: suspend () -> T): T = withTimeoutOrNull(ms.toLong()) { block() }
    ?: throw AssertionError("$label did not settle within $ms ms")

/** Runs `action`, returning whether it threw. A missed bound is a failure, not a throw. */
private suspend fun threw(action: suspend () -> Unit): Boolean = try {
    action()
    false
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    true
}

private fun JSONObject.requireObject(name: String): JSONObject = optJSONObject(name) ?: throw AssertionError("the case has no '$name' expectation")

/** Every wait and bound a handler uses comes from the case's own expectations. */
internal val audioOutputHandlers: Map<String, suspend (AudioOutputTarget, JSONObject) -> AudioOutputObservation> = mapOf(
    "open_makes_no_sound" to { target, _ ->
        val session = target.service.open(catalogFormat)
        settle(200)
        val defined = session.firstAudioMs() != null
        session.stop()
        AudioOutputObservation(firstAudioDefinedAfterOpen = defined)
    },
    "first_write_starts_playback" to { target, expected ->
        val waitMs = expected.optJSONObject("afterWrites")?.optInt("waitAtMostMs", 0) ?: 0
        val session = target.service.open(catalogFormat)
        val definedAfterOpen = session.firstAudioMs() != null
        session.write(tone(200))
        // Wall time on purpose: a real service reports first audio from its own thread, while
        // settle() is virtual under runTest.
        val deadline = System.nanoTime() + waitMs * 1_000_000L
        while (session.firstAudioMs() == null && System.nanoTime() < deadline) settle(10)
        val firstAudioMs = session.firstAudioMs()
        bounded(waitMs, "drain") { session.drain() }
        session.stop()
        AudioOutputObservation(
            firstAudioDefinedAfterOpen = definedAfterOpen,
            firstAudioDefinedAfterWrites = firstAudioMs != null,
            firstAudioMs = firstAudioMs,
        )
    },
    "drain_waits_for_everything_written" to { target, expected ->
        val timeoutMs = expected.requireObject("drain").getInt("timeoutMs")
        val session = target.service.open(catalogFormat)
        val from = target.now()
        session.write(tone(200))
        session.write(tone(200))
        bounded(timeoutMs, "drain") { session.drain() }
        val elapsed = target.now() - from
        session.stop()
        AudioOutputObservation(drainElapsedMs = elapsed)
    },
    "stop_discards_buffered_audio" to { target, expected ->
        val settlesWithinMs = expected.requireObject("stop").getInt("writeSettlesWithinMs")
        val session = target.service.open(catalogFormat)
        coroutineScope {
            val inFlight = async { session.write(tone(3000)) }
            settle(100)
            val stopThrew = threw { session.stop() }
            val stoppedAt = target.now()
            bounded(settlesWithinMs, "in-flight write") { inFlight.await() }
            val writeSettledAfterStopMs = target.now() - stoppedAt
            val drainFrom = target.now()
            val drainThrew = threw { bounded(settlesWithinMs, "drain after stop") { session.drain() } }
            AudioOutputObservation(
                stopThrew = stopThrew,
                writeSettledAfterStopMs = writeSettledAfterStopMs,
                drainAfterStopElapsedMs = target.now() - drainFrom,
                drainAfterStopThrew = drainThrew,
            )
        }
    },
    "stop_is_idempotent" to { target, expected ->
        val calls = expected.requireObject("stop").getInt("calls")
        val boundMs = expected.requireObject("drainAfterStop").getInt("elapsedAtMostMs")
        val session = target.service.open(catalogFormat)
        session.write(tone(200))
        var stopThrew = false
        var stopCalls = 0
        repeat(calls) {
            stopCalls++
            stopThrew = threw { session.stop() } || stopThrew
        }
        val drainFrom = target.now()
        val drainThrew = threw { bounded(boundMs, "drain after stop") { session.drain() } }
        AudioOutputObservation(
            stopThrew = stopThrew,
            stopCalls = stopCalls,
            drainAfterStopElapsedMs = target.now() - drainFrom,
            drainAfterStopThrew = drainThrew,
        )
    },
    "write_after_stop_is_ignored" to { target, expected ->
        val boundMs = expected.requireObject("writeAfterStop").getInt("elapsedAtMostMs")
        val session = target.service.open(catalogFormat)
        session.stop()
        val from = target.now()
        val writeThrew = threw { bounded(boundMs, "write after stop") { session.write(tone(200)) } }
        val elapsed = target.now() - from
        settle(300)
        AudioOutputObservation(
            writeAfterStopElapsedMs = elapsed,
            writeAfterStopThrew = writeThrew,
            firstAudioDefinedAfterWrites = session.firstAudioMs() != null,
        )
    },
    "drain_after_stop_resolves_at_once" to { target, expected ->
        val boundMs = expected.requireObject("drainAfterStop").getInt("elapsedAtMostMs")
        val session = target.service.open(catalogFormat)
        session.write(tone(200))
        session.stop()
        val from = target.now()
        val drainThrew = threw { bounded(boundMs, "drain after stop") { session.drain() } }
        AudioOutputObservation(drainAfterStopElapsedMs = target.now() - from, drainAfterStopThrew = drainThrew)
    },
    "sessions_are_independent" to { target, expected ->
        val timeoutMs = expected.requireObject("independence").getInt("timeoutMs")
        val a = target.service.open(catalogFormat)
        val b = target.service.open(catalogFormat)
        val from = target.now()
        a.write(tone(1000))
        b.write(tone(1000))
        a.stop()
        val stoppedFrom = target.now()
        bounded(timeoutMs, "drain of the stopped session") { a.drain() }
        val stoppedElapsed = target.now() - stoppedFrom
        bounded(timeoutMs, "drain of the other session") { b.drain() }
        val otherElapsed = target.now() - from
        b.stop()
        AudioOutputObservation(stoppedDrainElapsedMs = stoppedElapsed, otherDrainElapsedMs = otherElapsed)
    },
    "unsupported_format_refused" to { target, _ ->
        try {
            target.service.open(catalogFormat.copy(sampleRate = 4000)).stop()
            AudioOutputObservation()
        } catch (error: IndeRunException) {
            AudioOutputObservation(openRejection = error)
        }
    },
)

/** The catalog's `cases` array. The JSON is handed in so the instrumented run can read an asset. */
internal fun audioOutputCatalogCases(json: String): List<JSONObject> {
    val cases = JSONObject(json).getJSONArray("cases")
    return (0 until cases.length()).map { cases.getJSONObject(it) }
}

/** Compares [observed] with the case's `expect` data; returns one string per mismatch. */
internal fun checkAudioOutputCase(label: String, expected: JSONObject, observed: AudioOutputObservation): List<String> {
    val failures = mutableListOf<String>()
    fun require(condition: Boolean, what: () -> String) {
        if (!condition) failures += "$label: ${what()}"
    }
    fun <T> same(what: String, wanted: T, actual: T?) = require(wanted == actual) { "$what expected $wanted but was $actual" }
    fun atMost(what: String, bound: Double, actual: Double?) = require(actual != null && actual <= bound) { "$what expected at most $bound but was $actual" }
    fun atLeast(what: String, bound: Double, actual: Double?) = require(actual != null && actual >= bound) { "$what expected at least $bound but was $actual" }

    expected.optJSONObject("afterOpen")?.let {
        same("firstAudioDefined after open", it.getBoolean("firstAudioDefined"), observed.firstAudioDefinedAfterOpen)
    }
    expected.optJSONObject("afterWrites")?.let {
        same("firstAudioDefined after writes", it.getBoolean("firstAudioDefined"), observed.firstAudioDefinedAfterWrites)
        if (it.has("firstAudioAtMostMs")) atMost("firstAudioMs", it.getDouble("firstAudioAtMostMs"), observed.firstAudioMs)
    }
    expected.optJSONObject("drain")?.let {
        atLeast("drain elapsed", it.getDouble("elapsedAtLeastMs"), observed.drainElapsedMs)
    }
    expected.optJSONObject("stop")?.let {
        same("stop threw", it.getBoolean("throws"), observed.stopThrew)
        if (it.has("calls")) same("stop calls", it.getInt("calls"), observed.stopCalls)
        if (it.has("writeSettlesWithinMs")) {
            atMost("in-flight write settled after stop", it.getDouble("writeSettlesWithinMs"), observed.writeSettledAfterStopMs)
        }
    }
    expected.optJSONObject("writeAfterStop")?.let {
        atMost("write after stop elapsed", it.getDouble("elapsedAtMostMs"), observed.writeAfterStopElapsedMs)
        same("write after stop threw", it.getBoolean("throws"), observed.writeAfterStopThrew)
    }
    expected.optJSONObject("drainAfterStop")?.let {
        atMost("drain after stop elapsed", it.getDouble("elapsedAtMostMs"), observed.drainAfterStopElapsedMs)
        same("drain after stop threw", it.getBoolean("throws"), observed.drainAfterStopThrew)
    }
    expected.optJSONObject("independence")?.let {
        atMost("stopped session drain elapsed", it.getDouble("stoppedDrainAtMostMs"), observed.stoppedDrainElapsedMs)
        atLeast("other session drain elapsed", it.getDouble("otherDrainAtLeastMs"), observed.otherDrainElapsedMs)
    }
    expected.optJSONObject("openRejectsWith")?.let {
        val rejection = observed.openRejection
        require(rejection != null) { "expected open() to throw" }
        if (rejection != null) {
            same("open error class", IndeRunErrorClass.fromRawValue(it.getString("errorClass")), rejection.errorClass)
            same("open error details.code", it.getString("code"), rejection.details?.get("code"))
        }
    }
    return failures
}

/**
 * Runs the catalog (or only [ids]) against [target]; returns the failures, empty when every case
 * passed. A handler that fails an assertion or misses a bound is reported under its case id.
 */
internal suspend fun runAudioOutputCatalog(json: String, target: AudioOutputTarget, ids: Set<String>? = null): List<String> {
    val failures = mutableListOf<String>()
    for (case in audioOutputCatalogCases(json)) {
        val id = case.getString("id")
        if (ids != null && id !in ids) continue
        val handler = audioOutputHandlers[id]
        if (handler == null) {
            failures += "$id: no handler for this catalog case"
            continue
        }
        val expected = try {
            case.getJSONObject("expect")
        } catch (error: Exception) {
            failures += "$id: malformed case: ${error.message}"
            continue
        }
        val observed = try {
            handler(target, expected)
        } catch (error: AssertionError) {
            failures += "$id: handler failed: ${error.message}"
            continue
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            failures += "$id: handler threw ${error::class.simpleName}: ${error.message}"
            continue
        }
        failures += try {
            checkAudioOutputCase(id, expected, observed)
        } catch (error: org.json.JSONException) {
            listOf("$id: malformed case: ${error.message}")
        }
    }
    return failures
}
