package app.independo.inderun.core

import app.independo.inderun.contracts.Cloud
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.VoiceGender
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * The task-profile table (#245): every SDK projects a request onto the same planner task.
 * Each `current` file in `contracts/fixtures/task-contracts/` records the projection for its
 * requests; this test runs them through [buildSharedPlannerInput] and the hand-written
 * serializer, so a profile and the serializer are checked together.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class TaskContractFixtureTest {
    @Test
    fun `current fixtures project onto their planner task`() {
        val files = fixturesDir().listFiles { file -> file.name.endsWith(".json") }.orEmpty().sortedBy { it.name }
        var checked = 0

        for (file in files) {
            val fixture = JSONObject(file.readText(Charsets.UTF_8))
            if (fixture.getString("status") != "current") continue

            val cases = fixture.getJSONArray("cases")
            for (index in 0 until cases.length()) {
                val case = cases.getJSONObject(index)
                val id = "${fixture.getString("task")}/${case.getString("id")}"
                val request = parseTaskRequest(case.getJSONObject("request"))
                val task = JSONObject(buildSharedPlannerInput(request, online = true, snapshots = emptyList()).toJson())
                    .getJSONObject("task")

                assertEquals(id, normalize(case.getJSONObject("planner")), normalize(task))
                checked++
            }
        }

        assertTrue("No current task-contract fixture cases were found", checked > 0)
    }

    @Test
    fun `recheck refuses a network voice only under local_required`() {
        val voice = ProviderVoice(locale = "de-AT", networkRequired = true)
        val localRequired = speechRequest(privacy = Privacy.LocalRequired)

        val refusal = recheckBoundVoice(localRequired, "p", voice)

        assertEquals(IndeRunErrorClass.CapabilityMismatch, refusal?.errorClass)
        assertEquals("privacy_recheck_failed", refusal?.details?.get("code"))
        assertEquals("p", refusal?.providerId)
        assertNull(recheckBoundVoice(speechRequest(privacy = Privacy.LocalPreferred), "p", voice))
        assertNull(recheckBoundVoice(localRequired, "p", voice.copy(networkRequired = false)))
        assertNull(recheckBoundVoice(localRequired, "p", null))
    }

    @Test
    fun `text_to_speech validation reproduces the schema's per-kind rules`() {
        val profile = taskProfileFor(TaskKind.TEXT_TO_SPEECH)!!

        assertEquals(emptyList<String>(), profile.validate(speechRequest()))
        assertEquals(
            listOf("speech is required for task.kind 'text_to_speech'."),
            profile.validate(speechRequest().copy(speech = null)),
        )
        assertEquals(
            listOf("prompt is not allowed for task.kind 'text_to_speech'."),
            profile.validate(speechRequest().copy(prompt = "Hallo")),
        )
        assertEquals(
            listOf("delivery.mode must be 'playback' or 'artifact' for task.kind 'text_to_speech'."),
            profile.validate(speechRequest().copy(delivery = OutputDeliveryRequest(mode = OutputDelivery.Inline))),
        )
        assertEquals(
            listOf("delivery.mediaTypes is only allowed with delivery.mode 'artifact'."),
            profile.validate(
                speechRequest().copy(
                    delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback, mediaTypes = listOf("audio/wav")),
                ),
            ),
        )
        assertEquals(
            listOf("speech.voice with requirement 'required' must name a gender."),
            profile.validate(
                speechRequest().copy(
                    speech = SpeechInput(text = "Hallo", locale = "de-AT", voice = SpeechVoice(requirement = RequirementLevel.Required)),
                ),
            ),
        )
    }

    @Test
    fun `text_to_text validation forbids the speech payload`() {
        val profile = taskProfileFor(TaskKind.TEXT_TO_TEXT)!!
        val request = TaskRequest(schemaVersion = SchemaVersion.V1_0, prompt = "Hi", task = TaskRequestTask())

        assertEquals(emptyList<String>(), profile.validate(request))
        assertEquals(
            listOf("delivery is not allowed for task.kind 'text_to_text'."),
            profile.validate(request.copy(delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback))),
        )
        assertEquals(OutputDelivery.Inline, profile.delivery(request))
        assertEquals(OutputDelivery.Playback, taskProfileFor(TaskKind.TEXT_TO_SPEECH)!!.delivery(speechRequest()))
    }

    private fun speechRequest(privacy: Privacy? = null) = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(text = "Hallo", locale = "de-AT"),
        delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
        constraints = privacy?.let { TaskRequestConstraints(privacy = it) },
    )

    /**
     * Reads the request fields the fixtures use. There is no generated JSON decoder for the
     * Kotlin contracts, so a field a fixture adds must be added here before it is projected.
     */
    private fun parseTaskRequest(json: JSONObject): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.fromRawValue(json.getString("schemaVersion"))!!,
        requestId = json.optStringOrNull("requestId"),
        modelProfile = json.optStringOrNull("modelProfile"),
        task = TaskRequestTask(TaskKind.fromRawValue(json.getJSONObject("task").getString("kind"))!!),
        prompt = json.optStringOrNull("prompt"),
        messages = json.optJSONArray("messages")?.let { messages ->
            List(messages.length()) { index ->
                val message = messages.getJSONObject(index)
                Message(
                    role = MessageRole.fromRawValue(message.getString("role"))!!,
                    content = message.getString("content"),
                )
            }
        },
        speech = json.optJSONObject("speech")?.let { speech ->
            SpeechInput(
                text = speech.getString("text"),
                locale = speech.getString("locale"),
                localeMatch = speech.optStringOrNull("localeMatch")?.let { LocaleMatch.fromRawValue(it)!! },
                voice = speech.optJSONObject("voice")?.let { voice ->
                    SpeechVoice(
                        gender = voice.optStringOrNull("gender")?.let { VoiceGender.fromRawValue(it)!! },
                        requirement = voice.optStringOrNull("requirement")?.let { RequirementLevel.fromRawValue(it)!! },
                    )
                },
            )
        },
        delivery = json.optJSONObject("delivery")?.let { delivery ->
            OutputDeliveryRequest(
                mode = OutputDelivery.fromRawValue(delivery.getString("mode"))!!,
                mediaTypes = delivery.optJSONArray("mediaTypes")?.let { types -> List(types.length()) { types.getString(it) } },
            )
        },
        constraints = json.optJSONObject("constraints")?.let { constraints ->
            TaskRequestConstraints(
                privacy = constraints.optStringOrNull("privacy")?.let { Privacy.fromRawValue(it)!! },
                cloud = constraints.optStringOrNull("cloud")?.let { Cloud.fromRawValue(it)!! },
            )
        },
    )

    private fun JSONObject.optStringOrNull(name: String): String? = if (has(name)) getString(name) else null

    /** Key order is not significant in JSON, so compare sorted structures. */
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().associateWith { normalize(value.get(it)) }
        is JSONArray -> List(value.length()) { normalize(value.get(it)) }
        else -> value
    }

    private fun fixturesDir(): File {
        // The Gradle test working directory is the module directory; walk up to
        // the repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/task-contracts")
            if (candidate.isDirectory) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/task-contracts")
    }
}
