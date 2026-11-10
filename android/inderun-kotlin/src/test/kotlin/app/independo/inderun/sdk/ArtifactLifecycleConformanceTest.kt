package app.independo.inderun.sdk

import app.independo.inderun.contracts.ArtifactLifetime
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.ArtifactDestinationService
import app.independo.inderun.core.ArtifactLimits
import app.independo.inderun.core.ArtifactSink
import app.independo.inderun.core.ArtifactSpec
import app.independo.inderun.core.ArtifactWriter
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamCancellationToken
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * The Android half of the cross-SDK artifact-store catalog
 * (`contracts/fixtures/execution/artifact-lifecycle.json`, ADR 017). One handler per case id;
 * the guard test fails when the handler ids and the catalog ids differ.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class ArtifactLifecycleConformanceTest {
    private fun catalogFile(): File {
        // The Gradle test working directory is the module directory; walk up to the
        // repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/execution/artifact-lifecycle.json")
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/execution/artifact-lifecycle.json")
    }

    private fun catalogCases(): List<JSONObject> {
        val cases = JSONObject(catalogFile().readText(Charsets.UTF_8)).getJSONArray("cases")
        return (0 until cases.length()).map { cases.getJSONObject(it) }
    }

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val catalogIds = catalogCases().map { it.getString("id") }.sorted()
        assertTrue(catalogIds.isNotEmpty())
        assertEquals(catalogIds, artifactHandlers.keys.sorted())
    }

    @Test
    fun matchesTheSharedArtifactCatalog() = runTest {
        val failures = mutableListOf<String>()

        for (case in catalogCases()) {
            val id = case.getString("id")
            val handler = artifactHandlers[id]
            if (handler == null) {
                failures += "$id: no handler for this catalog case"
                continue
            }
            val observed = try {
                handler()
            } catch (error: AssertionError) {
                failures += "$id: handler failed: ${error.message}"
                continue
            }
            failures += checkArtifactCase(id, case.getJSONObject("expect"), observed)
        }

        assertTrue(
            "Conformance failures:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }
}

// --- the scripted provider ---------------------------------------------------

private val artifactRequest = TaskRequest(
    schemaVersion = SchemaVersion.V1_0,
    task = TaskRequestTask(TaskKind.TEXT_TO_SPEECH),
    speech = SpeechInput(text = "Hallo", locale = "de-AT"),
    delivery = OutputDeliveryRequest(mode = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav")),
    constraints = TaskRequestConstraints(privacy = Privacy.LocalRequired),
)

private val destinationRequest = artifactRequest.copy(
    delivery = OutputDeliveryRequest(mode = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav"), destinationRef = "dest_greeting"),
)

/** byte[i] = i % 251 over [start, start + length). */
private fun pattern(start: Long, length: Int): ByteArray = ByteArray(length) { ((start + it) % 251).toByte() }

private sealed interface ArtifactStep {
    data class Write(val bytes: Int) : ArtifactStep

    data object Finish : ArtifactStep

    /** Returns the artifact at [index] among those finished by this call. */
    data class ReturnFinished(val index: Int) : ArtifactStep

    /** Returns the first artifact this call finished, relabelled with another media type. */
    data class ReturnFinishedClaiming(val mediaType: String) : ArtifactStep

    data object ReturnForged : ArtifactStep

    data object Fail : ArtifactStep

    data object WaitForCancellation : ArtifactStep
}

/** A provider scripted in the catalog's vocabulary, recording what it observed. */
private class ArtifactFake(
    private val id: String,
    private val steps: List<ArtifactStep>,
    private val spec: ArtifactSpec = ArtifactSpec(mediaType = "audio/wav"),
) : StreamingProviderAdapter {
    var calls = 0
        private set
    val finished = mutableListOf<MediaArtifact>()
    val observedCodes = mutableListOf<String>()

    /** Completed once an artifact has been handed over. */
    val handedOver = CompletableDeferred<Unit>()

    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = id,
        type = ProviderType.Local,
        transport = ProviderTransport.InProcess,
        supports = ProviderSupports(
            run = true,
            streaming = true,
            realtime = false,
            tools = false,
            reasoningEvents = false,
            structuredOutput = false,
            multimodal = false,
        ),
        cancel = CancelSemantics.Hard,
        tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue),
        taskCapabilities = listOf(
            ProviderTaskCapability(
                kind = TaskKind.TEXT_TO_SPEECH.rawValue,
                inputs = listOf(TaskInputKind.Text),
                interaction = ProviderTaskInteraction(run = true, stream = true),
                cancel = CancelSemantics.Hard,
                outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav"))),
                locales = listOf("de-AT"),
            ),
        ),
    )

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
        schemaVersion = SchemaVersion.V1_0,
        runId = context.runId,
        output = checkNotNull(play(context.artifacts, null)),
        finishReason = FinishReason.STOP,
        telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
    )

    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
        play(context.artifacts, context.cancellation)?.let { emit(ProviderStreamEvent.Result(output = it)) }
    }

    private fun <T> observe(action: () -> T): T = try {
        action()
    } catch (error: IndeRunException) {
        (error.details?.get("code") as? String)?.let { observedCodes += it }
        throw error
    }

    private suspend fun play(artifacts: ArtifactSink, cancellation: StreamCancellationToken?): TaskOutput? {
        calls += 1
        // `ReturnFinished` indexes the artifacts this call finished.
        val firstOfCall = finished.size
        var writer: ArtifactWriter? = null
        var written = 0L
        for (step in steps) {
            when (step) {
                is ArtifactStep.Write -> {
                    val current = writer ?: artifacts.create(spec).also { writer = it }
                    observe { current.write(pattern(written, step.bytes)) }
                    written += step.bytes
                }

                ArtifactStep.Finish -> {
                    val current = writer ?: artifacts.create(spec)
                    finished += observe { current.finish() }
                    writer = null
                    written = 0
                    handedOver.complete(Unit)
                }

                is ArtifactStep.ReturnFinished ->
                    return TaskOutput(type = TaskOutputType.ARTIFACT, artifact = finished[firstOfCall + step.index])

                is ArtifactStep.ReturnFinishedClaiming ->
                    return TaskOutput(
                        type = TaskOutputType.ARTIFACT,
                        artifact = finished[firstOfCall].copy(mediaType = step.mediaType),
                    )

                ArtifactStep.ReturnForged -> return TaskOutput(
                    type = TaskOutputType.ARTIFACT,
                    artifact = MediaArtifact(
                        id = "art_forged",
                        mediaType = "audio/wav",
                        owner = ArtifactOwner.Engine,
                        lifetime = ArtifactLifetime.UntilDisposed,
                    ),
                )

                ArtifactStep.Fail -> throw createUnavailable("provider failed after handoff")

                ArtifactStep.WaitForCancellation -> {
                    val cancelled = CompletableDeferred<Unit>()
                    checkNotNull(cancellation) { "WaitForCancellation needs a stream" }.onCancel { cancelled.complete(Unit) }
                    cancelled.await()
                    return null
                }
            }
        }
        return null
    }
}

// --- handlers ------------------------------------------------------------------

private class ArtifactObservation(
    val engine: IndeRun,
    val fakes: List<ArtifactFake>,
    val output: TaskOutput? = null,
    val rejection: IndeRunException? = null,
    val attempts: List<List<String>>? = null,
    val runOutcomes: List<String>? = null,
    val events: List<StreamEvent>? = null,
    val destinationWrites: List<DestinationWrite>? = null,
)

private class DestinationWrite(val destinationRef: String, val artifact: MediaArtifact, val bytes: ByteArray)

/** A destination service that accepts every reference and records each write, or fails them all. */
/** With [blockWrites], a write waits for [release]; [writeStarted] completes when one begins. */
private class RecordingDestinations(
    private val failWrites: Boolean = false,
    private val blockWrites: Boolean = false,
) : ArtifactDestinationService {
    val writes = mutableListOf<DestinationWrite>()
    val writeStarted = CompletableDeferred<Unit>()
    private val released = CompletableDeferred<Unit>()

    fun release() {
        released.complete(Unit)
    }

    override suspend fun accepts(destinationRef: String, mediaTypes: List<String>?) = true

    override suspend fun write(destinationRef: String, artifact: MediaArtifact, bytes: ByteArray) {
        writeStarted.complete(Unit)
        if (blockWrites) released.await()
        if (failWrites) error("disk full at /private/dest_greeting")
        writes += DestinationWrite(destinationRef, artifact, bytes.copyOf())
    }
}

private fun engineWith(
    fakes: List<ArtifactFake>,
    limits: ArtifactLimits = ArtifactLimits(),
    host: HostServices = conformanceHostServices(),
): IndeRun {
    val registry = ProviderRegistry().apply { fakes.forEach { register(it) } }
    return IndeRun(registry, host, artifactLimits = limits)
}

private suspend fun runCase(
    fakes: List<ArtifactFake>,
    limits: ArtifactLimits = ArtifactLimits(),
    host: HostServices = conformanceHostServices(),
    request: TaskRequest = artifactRequest,
): ArtifactObservation {
    val engine = engineWith(fakes, limits, host)
    return try {
        val result = engine.run(request)
        ArtifactObservation(
            engine = engine,
            fakes = fakes,
            output = result.output,
            attempts = result.provenance?.attempts?.map { listOf(it.providerId, it.outcome.rawValue) },
        )
    } catch (error: IndeRunException) {
        ArtifactObservation(
            engine = engine,
            fakes = fakes,
            rejection = error,
            attempts = error.provenance?.attempts?.map { listOf(it.providerId, it.outcome.rawValue) },
        )
    }
}

private fun writeFinishReturn(bytes: Int) = listOf(ArtifactStep.Write(bytes), ArtifactStep.Finish, ArtifactStep.ReturnFinished(0))

private val artifactHandlers: Map<String, suspend () -> ArtifactObservation> = mapOf(
    "destination_unsupported_refused_before_routing" to {
        runCase(listOf(ArtifactFake("p1", writeFinishReturn(10))), request = destinationRequest)
    },
    "destination_written_and_store_released" to {
        val destinations = RecordingDestinations()
        val host = conformanceHostServices().copy(artifactDestinations = destinations)
        val observed = runCase(listOf(ArtifactFake("p1", writeFinishReturn(1000))), host = host, request = destinationRequest)
        ArtifactObservation(
            engine = observed.engine,
            fakes = observed.fakes,
            output = observed.output,
            rejection = observed.rejection,
            attempts = observed.attempts,
            destinationWrites = destinations.writes,
        )
    },
    "cancel_during_destination_write_is_cancelled" to {
        val destinations = RecordingDestinations(blockWrites = true)
        val fake = ArtifactFake("p1", writeFinishReturn(10))
        val engine = engineWith(listOf(fake), host = conformanceHostServices().copy(artifactDestinations = destinations))
        val run = engine.stream(destinationRequest)
        val events = mutableListOf<StreamEvent>()
        coroutineScope {
            val collector = launch { run.events.collect { events += it } }
            destinations.writeStarted.await()
            run.cancel()
            destinations.release()
            collector.join()
        }
        ArtifactObservation(
            engine = engine,
            fakes = listOf(fake),
            events = events,
            output = events.firstOrNull { it.type == "terminal" }?.payload?.output,
            destinationWrites = destinations.writes,
        )
    },
    "destination_write_failure_is_terminal" to {
        val host = conformanceHostServices().copy(artifactDestinations = RecordingDestinations(failWrites = true))
        runCase(
            listOf(ArtifactFake("p1", writeFinishReturn(10)), ArtifactFake("p2", writeFinishReturn(10))),
            host = host,
            request = destinationRequest,
        )
    },
    "read_full" to {
        runCase(listOf(ArtifactFake("p1", writeFinishReturn(1000), ArtifactSpec(mediaType = "audio/wav", durationMs = 500.0))))
    },
    "chunked_reads_cover_bytes_once" to {
        runCase(
            listOf(
                ArtifactFake(
                    "p1",
                    listOf(
                        ArtifactStep.Write(300),
                        ArtifactStep.Write(300),
                        ArtifactStep.Write(400),
                        ArtifactStep.Finish,
                        ArtifactStep.ReturnFinished(0),
                    ),
                ),
            ),
        )
    },
    "read_is_bounded_by_the_engine_limit" to {
        runCase(listOf(ArtifactFake("p1", writeFinishReturn(1000))), ArtifactLimits(maxReadBytes = 256))
    },
    "repeated_reads_identical" to { runCase(listOf(ArtifactFake("p1", writeFinishReturn(1000)))) },
    "read_at_end_is_empty_and_beyond_end_is_rejected" to { runCase(listOf(ArtifactFake("p1", writeFinishReturn(1000)))) },
    "dispose_is_idempotent_then_not_found" to {
        val observed = runCase(listOf(ArtifactFake("p1", writeFinishReturn(10))))
        val artifact = checkNotNull(observed.output?.artifact)
        observed.engine.disposeArtifact(artifact)
        observed.engine.disposeArtifact(artifact)
        observed
    },
    "unknown_id_not_found" to { ArtifactObservation(engine = engineWith(emptyList()), fakes = emptyList()) },
    "post_handoff_failure_is_terminal_and_disposes" to {
        runCase(
            listOf(
                ArtifactFake("p1", listOf(ArtifactStep.Write(10), ArtifactStep.Finish, ArtifactStep.Fail)),
                ArtifactFake("p2", writeFinishReturn(10)),
            ),
        )
    },
    "stored_media_type_decides_the_match" to {
        runCase(
            listOf(
                ArtifactFake(
                    "p1",
                    listOf(ArtifactStep.Write(10), ArtifactStep.Finish, ArtifactStep.ReturnFinishedClaiming("audio/wav")),
                    ArtifactSpec(mediaType = "audio/mpeg"),
                ),
                ArtifactFake("p2", writeFinishReturn(10)),
            ),
        )
    },
    "too_large_is_pre_commit_and_falls_back" to {
        runCase(
            listOf(ArtifactFake("p1", writeFinishReturn(101)), ArtifactFake("p2", writeFinishReturn(50))),
            ArtifactLimits(maxArtifactBytes = 100),
        )
    },
    "store_full_refuses_handoff_until_disposed" to {
        val fake = ArtifactFake("p1", writeFinishReturn(100))
        val engine = engineWith(listOf(fake), ArtifactLimits(maxStoreBytes = 150))
        val runOutcomes = mutableListOf<String>()
        var rejection: IndeRunException? = null
        val first = engine.run(artifactRequest)
        runOutcomes += "succeeded"
        try {
            engine.run(artifactRequest)
            runOutcomes += "succeeded"
        } catch (error: IndeRunException) {
            rejection = error
            runOutcomes += "rejected"
        }
        engine.disposeArtifact(checkNotNull(first.output.artifact))
        try {
            engine.run(artifactRequest)
            runOutcomes += "succeeded"
        } catch (_: IndeRunException) {
            runOutcomes += "rejected"
        }
        ArtifactObservation(engine = engine, fakes = listOf(fake), rejection = rejection, runOutcomes = runOutcomes)
    },
    "unreturned_artifacts_disposed" to {
        runCase(
            listOf(
                ArtifactFake(
                    "p1",
                    listOf(
                        ArtifactStep.Write(10),
                        ArtifactStep.Finish,
                        ArtifactStep.Write(20),
                        ArtifactStep.Finish,
                        ArtifactStep.ReturnFinished(1),
                    ),
                ),
            ),
        )
    },
    "foreign_artifact_is_output_mismatch" to {
        runCase(listOf(ArtifactFake("p1", listOf(ArtifactStep.ReturnForged)), ArtifactFake("p2", writeFinishReturn(10))))
    },
    "cancelled_stream_disposes_artifact" to {
        val fake = ArtifactFake("p1", listOf(ArtifactStep.Write(10), ArtifactStep.Finish, ArtifactStep.WaitForCancellation))
        val engine = engineWith(listOf(fake))
        val run = engine.stream(artifactRequest)
        val events = mutableListOf<StreamEvent>()
        coroutineScope {
            val collector = launch { run.events.collect { events += it } }
            fake.handedOver.await()
            run.cancel()
            collector.join()
        }
        ArtifactObservation(engine = engine, fakes = listOf(fake), events = events)
    },
    "events_carry_no_media_bytes" to {
        val fake = ArtifactFake("p1", writeFinishReturn(1_048_576))
        val engine = engineWith(listOf(fake))
        val events = engine.stream(artifactRequest).events.toList()
        val output = events.firstOrNull { it.type == "terminal" }?.payload?.output
        ArtifactObservation(engine = engine, fakes = listOf(fake), events = events, output = output)
    },
)

// --- assertions ----------------------------------------------------------------

private fun JSONObject.readRequest(artifactId: String): ArtifactReadRequest = ArtifactReadRequest(
    artifactId = optString("artifactId", artifactId),
    offset = if (has("offset")) getLong("offset") else null,
    maxBytes = if (has("maxBytes")) getLong("maxBytes") else null,
)

private fun MediaArtifact.fields(): Map<String, Any?> = buildMap {
    put("mediaType", mediaType)
    put("owner", owner.rawValue)
    put("lifetime", lifetime.rawValue)
    byteLength?.let { put("byteLength", it) }
    durationMs?.let { put("durationMs", it) }
    destinationRef?.let { put("destinationRef", it) }
}

private fun JSONObject.expectedFields(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (key) {
        "byteLength" -> getLong(key)
        "durationMs" -> getDouble(key)
        else -> getString(key)
    }
}

@Suppress("CyclomaticComplexMethod", "LongMethod")
private suspend fun checkArtifactCase(label: String, expected: JSONObject, observed: ArtifactObservation): List<String> {
    val failures = mutableListOf<String>()
    fun require(condition: Boolean, what: () -> String) {
        if (!condition) failures += "$label: ${what()}"
    }
    fun <T> same(what: String, wanted: T, actual: T) = require(wanted == actual) { "$what expected $wanted but was $actual" }

    val engine = observed.engine
    val artifact = observed.output?.artifact

    expected.optJSONObject("output")?.let { wanted ->
        require(artifact != null) { "expected an artifact output" }
        if (artifact != null) {
            require(artifact.id.isNotEmpty()) { "expected an artifact id" }
            same("output", wanted.expectedFields(), artifact.fields())
        }
    }

    expected.optJSONArray("reads")?.let { reads ->
        for (index in 0 until reads.length()) {
            val read = reads.getJSONObject(index)
            val request = read.getJSONObject("request").readRequest(artifact?.id ?: "art_unknown")
            val chunk = try {
                engine.readArtifact(request)
            } catch (error: IndeRunException) {
                failures += "$label: read $index threw ${error.errorClass} ${error.details}"
                continue
            }
            same(
                "read $index",
                listOf(read.getLong("offset"), read.getInt("length").toLong(), read.getLong("totalBytes"), read.getBoolean("done")),
                listOf(chunk.offset, chunk.bytes.size.toLong(), chunk.totalBytes, chunk.done),
            )
            require(chunk.bytes.contentEquals(pattern(chunk.offset, chunk.bytes.size))) { "read $index bytes do not follow the pattern" }
        }
    }

    expected.optJSONArray("readRejects")?.let { rejects ->
        for (index in 0 until rejects.length()) {
            val rejected = rejects.getJSONObject(index)
            val request = rejected.getJSONObject("request").readRequest(artifact?.id ?: "art_unknown")
            val error = try {
                engine.readArtifact(request)
                null
            } catch (caught: IndeRunException) {
                caught
            }
            require(error != null) { "expected readArtifact $index to throw" }
            if (error == null) continue
            same("readRejects $index errorClass", rejected.getString("errorClass"), error.errorClass.rawValue)
            if (rejected.has("retryable")) same("readRejects $index retryable", rejected.getBoolean("retryable"), error.retryable)
            if (rejected.has("code")) same("readRejects $index code", rejected.getString("code"), error.details?.get("code"))
            if (rejected.has("validationIssuePath")) {
                val paths = (error.details?.get("validationIssues") as? List<*>).orEmpty().map { (it as? Map<*, *>)?.get("path") }
                require(rejected.getString("validationIssuePath") in paths) { "readRejects $index validation paths were $paths" }
            }
        }
    }

    expected.optJSONObject("runRejectsWith")?.let { wanted ->
        val rejection = observed.rejection
        require(rejection != null) { "expected run() to throw" }
        if (rejection != null) {
            same("runRejectsWith errorClass", wanted.getString("errorClass"), rejection.errorClass.rawValue)
            if (wanted.has("code")) same("runRejectsWith code", wanted.getString("code"), rejection.details?.get("code"))
        }
    }

    expected.optJSONObject("rejectsBeforeRouting")?.let { wanted ->
        val rejection = observed.rejection
        require(rejection != null) { "expected run() to throw" }
        if (rejection != null) {
            same("rejectsBeforeRouting errorClass", wanted.getString("errorClass"), rejection.errorClass.rawValue)
            same("rejectsBeforeRouting code", wanted.getString("code"), rejection.details?.get("code"))
            same("rejectsBeforeRouting attempts", emptyList<List<String>>(), observed.attempts.orEmpty())
        }
    }

    expected.optJSONArray("destinationWrites")?.let { wanted ->
        same(
            "destinationWrites",
            (0 until wanted.length()).map { index ->
                val write = wanted.getJSONObject(index)
                listOf(write.getString("destinationRef"), write.getString("mediaType"), write.getInt("byteLength"), write.getBoolean("bytesMatchPattern"))
            },
            observed.destinationWrites.orEmpty().map { write ->
                listOf(write.destinationRef, write.artifact.mediaType, write.bytes.size, write.bytes.contentEquals(pattern(0, write.bytes.size)))
            },
        )
    }

    expected.optJSONArray("runs")?.let { wanted ->
        same("runs", (0 until wanted.length()).map { wanted.getString(it) }, observed.runOutcomes)
    }

    fun fake(providerId: String) = observed.fakes.firstOrNull { it.describe().id == providerId }

    expected.optJSONObject("providerCallCounts")?.let { wanted ->
        for (providerId in wanted.keys()) same("calls of $providerId", wanted.getInt(providerId), fake(providerId)?.calls)
    }

    expected.optJSONArray("attempts")?.let { wanted ->
        val attempts = (0 until wanted.length()).map { index ->
            val pair = wanted.getJSONArray(index)
            listOf(pair.getString(0), pair.getString(1))
        }
        same("attempts", attempts, observed.attempts)
    }

    expected.optJSONObject("providerObservedCodes")?.let { wanted ->
        for (providerId in wanted.keys()) {
            val codes = wanted.getJSONArray(providerId)
            same("observed codes of $providerId", (0 until codes.length()).map { codes.getString(it) }, fake(providerId)?.observedCodes)
        }
    }

    expected.optJSONObject("finishedReadable")?.let { wanted ->
        for (providerId in wanted.keys()) {
            val readable = wanted.getJSONArray(providerId)
            val actual = fake(providerId)?.finished.orEmpty().map { finished ->
                try {
                    engine.readArtifact(ArtifactReadRequest(artifactId = finished.id))
                    true
                } catch (_: IndeRunException) {
                    false
                }
            }
            same("finishedReadable of $providerId", (0 until readable.length()).map { readable.getBoolean(it) }, actual)
        }
    }

    expected.optJSONObject("terminal")?.let { wanted ->
        val terminal = observed.events?.lastOrNull { it.type == "terminal" }?.payload
        require(terminal != null) { "expected a terminal event" }
        if (terminal != null) {
            if (wanted.has("outcome")) same("terminal outcome", wanted.getString("outcome"), terminal.outcome?.rawValue)
            if (wanted.optBoolean("absentOutput")) same("terminal output", null, terminal.output)
        }
    }

    if (expected.has("maxSerializedEventBytes")) {
        // No contract JSON encoder exists on Android; an event's string form spells every field,
        // nulls included, so it bounds the JSON encoding from above.
        val limit = expected.getInt("maxSerializedEventBytes")
        observed.events.orEmpty().forEach { event ->
            val size = event.toString().toByteArray(Charsets.UTF_8).size
            require(size < limit) { "event ${event.type} is $size bytes, expected below $limit" }
        }
    }

    return failures
}
