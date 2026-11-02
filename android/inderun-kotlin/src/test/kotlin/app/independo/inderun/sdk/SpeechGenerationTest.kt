package app.independo.inderun.sdk

import app.independo.inderun.contracts.ArtifactLifetime
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Cloud
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.OptimizeFor
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
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
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechOutput
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.core.ArtifactChunk
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.StreamRun
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * An [IndeRunApi] that answers `listVoices` from fixed snapshots and `generateSpeech` from a fixed
 * result: the facade is tested against the interface, not an engine.
 */
private class ScriptedApi(
    private val snapshots: List<ProviderCapabilitySnapshot> = emptyList(),
    private val result: TaskResult? = null,
) : IndeRunApi {
    override suspend fun run(request: TaskRequest): TaskResult = result!!

    override suspend fun prepare(request: app.independo.inderun.contracts.PrepareRequest): app.independo.inderun.core.StreamRun = error("not scripted")

    override suspend fun stream(request: TaskRequest): StreamRun = error("not scripted")

    override suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> = snapshots

    override suspend fun readArtifact(request: ArtifactReadRequest): ArtifactChunk = error("not scripted")

    override suspend fun disposeArtifact(artifact: MediaArtifact) = Unit
}

@RunWith(RobolectricTestRunner::class)
class SpeechGenerationTest {
    // --- shared vectors ----------------------------------------------------------------------

    private fun fixtureCases(path: String): List<JSONObject> {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, path)
            if (candidate.exists()) {
                val cases = JSONObject(candidate.readText()).getJSONArray("cases")
                return (0 until cases.length()).map { cases.getJSONObject(it) }
            }
            directory = directory.parentFile
        }
        error("Could not locate $path")
    }

    private fun JSONObject.stringOrNull(key: String): String? = if (has(key)) getString(key) else null

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun speakOptionsFrom(json: JSONObject) = SpeakOptions(
        text = json.getString("text"),
        locale = json.getString("locale"),
        localeMatch = json.stringOrNull("localeMatch")?.let(LocaleMatch::fromRawValue),
        voice = json.optJSONObject("voice")?.let { voice ->
            SpeechVoice(
                gender = voice.stringOrNull("gender")?.let(VoiceGender::fromRawValue),
                id = voice.stringOrNull("id"),
                providerId = voice.stringOrNull("providerId"),
                requirement = voice.stringOrNull("requirement")?.let(RequirementLevel::fromRawValue),
            )
        },
        model = json.stringOrNull("model"),
        execution = json.optJSONObject("execution")?.let { execution ->
            SpeechExecutionOptions(
                privacy = execution.stringOrNull("privacy")?.let(Privacy::fromRawValue),
                cloud = execution.stringOrNull("cloud")?.let(Cloud::fromRawValue),
                timeoutMs = if (execution.has("timeoutMs")) execution.getLong("timeoutMs") else null,
                optimizeFor = execution.stringOrNull("optimizeFor")?.let(OptimizeFor::fromRawValue),
            )
        },
        authContextRef = json.stringOrNull("authContextRef"),
        requestId = json.stringOrNull("requestId"),
    )

    private fun TaskRequest.toJsonValue(): Map<String, Any?> = buildMap {
        put("schemaVersion", schemaVersion.rawValue)
        put("task", mapOf("kind" to task.kind.rawValue))
        put(
            "speech",
            buildMap {
                speech?.text?.let { put("text", it) }
                speech?.locale?.let { put("locale", it) }
                speech?.localeMatch?.let { put("localeMatch", it.rawValue) }
                speech?.voice?.let { voice ->
                    put(
                        "voice",
                        buildMap {
                            voice.id?.let { put("id", it) }
                            voice.providerId?.let { put("providerId", it) }
                            voice.gender?.let { put("gender", it.rawValue) }
                            voice.requirement?.let { put("requirement", it.rawValue) }
                        },
                    )
                }
            },
        )
        put(
            "delivery",
            buildMap {
                delivery?.mode?.let { put("mode", it.rawValue) }
                delivery?.mediaTypes?.let { put("mediaTypes", it) }
                delivery?.destinationRef?.let { put("destinationRef", it) }
            },
        )
        modelProfile?.let { put("modelProfile", it) }
        constraints?.let { constraints ->
            put(
                "constraints",
                buildMap {
                    constraints.privacy?.let { put("privacy", it.rawValue) }
                    constraints.cloud?.let { put("cloud", it.rawValue) }
                    constraints.timeoutMs?.let { put("timeoutMs", it) }
                },
            )
        }
        preferences?.optimizeFor?.let { put("preferences", mapOf("optimizeFor" to it.rawValue)) }
        authContextRef?.let { put("authContextRef", it) }
        requestId?.let { put("requestId", it) }
    }

    private fun Any?.normalized(): Any? = when (this) {
        is JSONObject -> keys().asSequence().associateWith { get(it).normalized() }
        is JSONArray -> (0 until length()).map { get(it).normalized() }
        is Map<*, *> -> entries.associate { (key, value) -> key to value.normalized() }
        is List<*> -> map { it.normalized() }
        is Int -> toLong()
        else -> this
    }

    @Test
    fun matchesTheSharedFacadeVectors() {
        val cases = fixtureCases("contracts/fixtures/facade/speech.json")
        assertTrue(cases.isNotEmpty())
        for (vector in cases) {
            val raw = vector.getJSONObject("options")
            val speak = speakOptionsFrom(raw)
            val request = if (vector.getString("call") == "speak") {
                speak.toTaskRequest()
            } else {
                GenerateSpeechOptions(
                    speak,
                    mediaTypes = raw.optJSONArray("mediaTypes")?.strings(),
                    destinationRef = raw.stringOrNull("destinationRef"),
                ).toTaskRequest()
            }
            assertEquals(
                vector.getString("id"),
                vector.getJSONObject("expected").normalized(),
                request.toJsonValue().normalized(),
            )
        }
    }

    @Test
    fun matchesTheSharedVoiceLocalityVectors() {
        val cases = fixtureCases("contracts/fixtures/execution/voice-locality.json")
        assertTrue(cases.isNotEmpty())
        for (vector in cases) {
            val leaves = if (vector.has("taskDataLeavesDevice")) vector.getBoolean("taskDataLeavesDevice") else null
            val descriptor = speechDescriptor(ProviderType.fromRawValue(vector.getString("providerType"))!!, leaves)
            val bound = vector.optJSONObject("voice")?.let { voice ->
                TaskKind.TEXT_TO_SPEECH.rawValue to ProviderVoice(
                    locale = voice.getString("locale"),
                    networkRequired = if (voice.has("networkRequired")) voice.getBoolean("networkRequired") else null,
                )
            } ?: (TaskKind.TEXT_TO_SPEECH.rawValue to null).takeIf { vector.optBoolean("unverifiedVoice") }
            assertEquals(vector.getString("id"), vector.getString("expected"), localityOf(descriptor, bound).rawValue)
        }
    }

    private fun speechDescriptor(type: ProviderType, taskDataLeavesDevice: Boolean? = null) = ProviderDescriptor(
        cancel = CancelSemantics.Hard,
        id = "p",
        supports = ProviderSupports(
            multimodal = false,
            realtime = false,
            reasoningEvents = false,
            run = true,
            streaming = false,
            structuredOutput = false,
            tools = false,
        ),
        tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue),
        taskCapabilities = listOf(
            ProviderTaskCapability(
                cancel = CancelSemantics.Hard,
                inputs = listOf(TaskInputKind.Text),
                interaction = ProviderTaskInteraction(run = true, stream = false),
                kind = TaskKind.TEXT_TO_SPEECH.rawValue,
                outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                privacy = taskDataLeavesDevice?.let { ProviderPrivacy(dataLeavesDevice = it) },
            ),
        ),
        transport = ProviderTransport.SystemService,
        type = type,
    )

    // --- speak -------------------------------------------------------------------------------

    private val options = SpeakOptions("Hallo", locale = "de-AT")

    private fun engine(provider: FakeStreamProvider): IndeRun = IndeRun(ProviderRegistry().apply { register(provider) }, conformanceHostServices())

    @Test
    fun speakResolvesWithWhatPlayedAndTheProvenance() = runBlocking {
        val output = TaskOutput(
            type = TaskOutputType.PLAYBACK,
            playback = PlaybackOutput(durationMs = 1200.0),
            speech = SpeechOutput(locale = "de-DE"),
        )
        val inderun = engine(
            FakeStreamProvider(
                "tts",
                script = listOf(Step.Commit, Step.Emit(ProviderStreamEvent.Result(output, FinishReason.STOP))),
                task = TaskKind.TEXT_TO_SPEECH,
            ),
        )

        val ending = inderun.speak(options, CoroutineScope(Dispatchers.Default)).result.await()

        assertEquals(FinishReason.STOP, ending.finishReason)
        assertEquals(1200.0, ending.durationMs)
        assertEquals("de-DE", ending.speech?.locale)
        assertEquals("tts", ending.provenance?.providerId)
        assertEquals(true, ending.provenance?.attempts?.single()?.committed)
        assertEquals(Locality.Unknown, ending.provenance?.locality)
    }

    @Test
    fun cancelStopsPlaybackAndResolvesRatherThanThrows() = runBlocking {
        val inderun = engine(
            FakeStreamProvider("tts", script = listOf(Step.Commit, Step.WaitForCancellation), task = TaskKind.TEXT_TO_SPEECH),
        )

        val playback = inderun.speak(options, CoroutineScope(Dispatchers.Default))
        // Let the attempt reach its commit, so the cancel stops audio rather than preventing it.
        delay(50)
        playback.cancel("stop")
        playback.cancel("again")
        val ending = playback.result.await()

        assertEquals(FinishReason.CANCELLED, ending.finishReason)
        assertEquals(AttemptOutcome.Cancelled, ending.provenance?.attempts?.single()?.outcome)
        assertEquals(true, ending.provenance?.attempts?.single()?.committed)
    }

    @Test
    fun aFailedRunFailsTheResultWithItsProvenance() = runBlocking {
        val inderun = engine(
            FakeStreamProvider(
                "tts",
                script = listOf(Step.Commit),
                throwAfterScript = createUnavailable("gone"),
                task = TaskKind.TEXT_TO_SPEECH,
            ),
        )

        val playback = inderun.speak(options, CoroutineScope(Dispatchers.Default))
        try {
            playback.result.await()
            fail("expected the run to fail")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Unavailable, error.errorClass)
            assertEquals("tts", error.provenance?.providerId)
        }
    }

    // --- generateSpeech ----------------------------------------------------------------------

    private fun taskResult(output: TaskOutput) = TaskResult(
        finishReason = FinishReason.STOP,
        output = output,
        runId = "run_1",
        schemaVersion = SchemaVersion.V1_0,
        telemetry = TaskResultTelemetry(providerUsed = "tts", totalMs = 1.0),
    )

    @Test
    fun generateSpeechReturnsTheArtifactWithWhatWasUsed() = runTest {
        val artifact = MediaArtifact(
            byteLength = 44,
            id = "art_1",
            lifetime = ArtifactLifetime.UntilDisposed,
            mediaType = "audio/wav",
            owner = ArtifactOwner.Engine,
        )
        val output = TaskOutput(type = TaskOutputType.ARTIFACT, artifact = artifact, speech = SpeechOutput(locale = "de-DE"))

        val speech = ScriptedApi(result = taskResult(output)).generateSpeech(GenerateSpeechOptions(options))

        assertEquals(artifact, speech.artifact)
        assertEquals("de-DE", speech.speech?.locale)
        assertEquals(FinishReason.STOP, speech.finishReason)
        assertEquals("run_1", speech.runId)
        assertNull(speech.provenance)
    }

    @Test
    fun generateSpeechRefusesAResultWithoutAnArtifact() = runTest {
        val api = ScriptedApi(result = taskResult(TaskOutput(type = TaskOutputType.TEXT, text = "not audio")))

        try {
            api.generateSpeech(GenerateSpeechOptions(options))
            fail("expected a failure")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        }
    }

    // --- listVoices --------------------------------------------------------------------------

    private fun snapshot(
        id: String,
        available: Boolean = true,
        taskAvailable: Boolean? = null,
        voices: List<ProviderVoice>?,
    ) = ProviderCapabilitySnapshot(
        capabilities = ProviderDynamicCapabilities(
            available = available,
            taskCapabilities = voices?.let {
                listOf(ProviderTaskAvailability(available = taskAvailable, kind = TaskKind.TEXT_TO_SPEECH.rawValue, voices = it))
            },
        ),
        descriptor = speechDescriptor(ProviderType.Local),
        providerId = id,
    )

    private val voiceApi = ScriptedApi(
        snapshots = listOf(
            snapshot("text_only", voices = null),
            snapshot("off", available = false, voices = listOf(ProviderVoice(locale = "de-DE"))),
            snapshot("task_off", taskAvailable = false, voices = listOf(ProviderVoice(locale = "de-DE"))),
            snapshot(
                "tts",
                voices = listOf(
                    ProviderVoice(gender = VoiceGender.Female, locale = "de-DE", networkRequired = false),
                    ProviderVoice(locale = "de_AT"),
                    ProviderVoice(locale = "en-GB", networkRequired = true),
                ),
            ),
        ),
    )

    @Test
    fun listsTheVoicesOfAvailableProvidersInOrder() = runTest {
        assertEquals(
            listOf(
                SpeechVoiceInfo("tts", "de-DE", VoiceGender.Female, false),
                SpeechVoiceInfo("tts", "de_AT"),
                SpeechVoiceInfo("tts", "en-GB", networkRequired = true),
            ),
            voiceApi.listVoices(),
        )
    }

    @Test
    fun matchesALocaleByLanguageByDefault() = runTest {
        assertEquals(listOf("de-DE", "de_AT"), voiceApi.listVoices(locale = "de-AT").map { it.locale })
    }

    @Test
    fun matchesTheWholeTagWhenAskedTo() = runTest {
        assertEquals(listOf("de-DE"), voiceApi.listVoices("DE-de", LocaleMatch.Exact).map { it.locale })
    }

    @Test
    fun aCatalogEntryBecomesAScopedRequestVoice() {
        val voice = SpeechVoiceInfo("tts", "de-DE", VoiceGender.Female, id = "anna", name = "Anna")
            .asSpeechVoice(RequirementLevel.Required)

        assertEquals("anna", voice.id)
        assertEquals("tts", voice.providerId)
        assertEquals(VoiceGender.Female, voice.gender)
        assertEquals(RequirementLevel.Required, voice.requirement)
    }

    @Test
    fun aCatalogEntryWithoutAnIdSelectsByTraits() {
        val voice = SpeechVoiceInfo("tts", "de-DE", VoiceGender.Female).asSpeechVoice()

        assertEquals(null, voice.providerId)
        assertEquals(VoiceGender.Female, voice.gender)
    }
}
