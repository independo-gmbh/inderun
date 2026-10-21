package app.independo.inderun.core

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Cloud
import app.independo.inderun.contracts.DeliveryRequirement
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.LocaleRequirement
import app.independo.inderun.contracts.ModelProfile
import app.independo.inderun.contracts.OptimizeFor
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.Provider
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderLimits
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
import app.independo.inderun.contracts.RoutePlannerInputConstraints
import app.independo.inderun.contracts.RoutePlannerInputPreferences
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.StreamingStyle
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.contracts.VoiceRequirement
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * `toJson` is hand-written, so a property added to `route-planner-input.schema.json` or to
 * a provider schema it references is silently dropped unless someone remembers to mirror
 * it. This test turns that reminder into a failure: it walks the schemas (following
 * `$ref`), serializes an input with every optional field set, and requires every schema
 * property path to appear in the output.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class SharedPlannerInputSerializationCoverageTest {
    @Test
    fun `every planner-input schema property is serialized`() {
        val schemasDir = schemasDir()
        val schemaPaths = sortedSetOf<String>()
        collectSchemaPaths(
            schema = JSONObject(File(schemasDir, "route-planner-input.schema.json").readText()),
            schemasDir = schemasDir,
            prefix = "",
            into = schemaPaths,
        )

        val emittedPaths = sortedSetOf<String>()
        collectJsonPaths(JSONObject(fullyPopulatedInput().toJson()), "", emittedPaths)

        assertEquals(
            "Schema properties missing from SharedPlannerInput.toJson()",
            emptySet<String>(),
            schemaPaths - emittedPaths,
        )
    }

    private fun fullyPopulatedInput(): SharedPlannerInput = SharedPlannerInput(
        task = RoutePlannerInputTask(
            kind = "text_to_speech",
            inputs = listOf(TaskInputKind.Text),
            delivery = DeliveryRequirement(mode = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav")),
            locale = LocaleRequirement(tag = "de-AT", match = LocaleMatch.Language),
            voice = VoiceRequirement(gender = VoiceGender.Female, requirement = RequirementLevel.Required),
        ),
        interactionMode = InteractionMode.Stream,
        constraints = RoutePlannerInputConstraints(
            privacy = Privacy.LocalPreferred,
            cloud = Cloud.Allowed,
            networkOnline = true,
        ),
        preferences = RoutePlannerInputPreferences(optimizeFor = OptimizeFor.Balanced),
        modelProfile = ModelProfile(name = "smart", targetIds = listOf("provider_a")),
        providers = listOf(
            Provider(
                descriptor = ProviderDescriptor(
                    id = "provider_a",
                    type = ProviderType.Cloud,
                    model = "model-a",
                    transport = ProviderTransport.SSE,
                    streamingStyle = StreamingStyle.Tokens,
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
                    tasks = listOf("text_to_speech"),
                    taskCapabilities = listOf(
                        ProviderTaskCapability(
                            kind = "text_to_speech",
                            inputs = listOf(TaskInputKind.Text),
                            interaction = ProviderTaskInteraction(run = true, stream = false),
                            cancel = CancelSemantics.Hard,
                            outputs = listOf(
                                ProviderTaskOutput(delivery = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav")),
                            ),
                            locales = listOf("de-DE"),
                            privacy = ProviderPrivacy(dataLeavesDevice = false, regions = listOf("eu")),
                        ),
                    ),
                    limits = ProviderLimits(
                        maxInputTokens = 1,
                        maxOutputTokens = 1,
                        maxImageBytes = 1,
                        maxAudioSeconds = 1,
                    ),
                    privacy = ProviderPrivacy(dataLeavesDevice = true, regions = listOf("eu")),
                ),
                capabilities = ProviderDynamicCapabilities(
                    available = false,
                    reason = "reason",
                    streamingAvailable = false,
                    streamingUnavailableReason = "streaming reason",
                    cancellationAvailable = false,
                    taskCapabilities = listOf(
                        ProviderTaskAvailability(
                            kind = "text_to_speech",
                            available = false,
                            reason = "task reason",
                            streamingAvailable = false,
                            streamingUnavailableReason = "task streaming reason",
                            cancellationAvailable = false,
                            locales = listOf("de-DE"),
                            voices = listOf(
                                ProviderVoice(locale = "de-DE", gender = VoiceGender.Female, networkRequired = false),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )

    private fun collectSchemaPaths(
        schema: JSONObject,
        schemasDir: File,
        prefix: String,
        into: MutableSet<String>,
        currentFile: String = "route-planner-input.schema.json",
    ) {
        schema.optString("\$ref").takeUnless { it.isEmpty() }?.let { ref ->
            collectSchemaPaths(resolveRef(ref, schemasDir, currentFile), schemasDir, prefix, into, refFile(ref, currentFile))
        }
        schema.optJSONObject("properties")?.let { properties ->
            for (key in properties.keys()) {
                val path = "$prefix/$key"
                into += path
                collectSchemaPaths(properties.getJSONObject(key), schemasDir, path, into, currentFile)
            }
        }
        schema.optJSONObject("items")?.let { items ->
            collectSchemaPaths(items, schemasDir, "$prefix[]", into, currentFile)
        }
    }

    private fun refFile(ref: String, currentFile: String): String = ref.substringBefore('#').ifEmpty { currentFile }

    /** Resolves `file.json`, `file.json#/a/b` and `#/a/b` against the schemas directory. */
    private fun resolveRef(ref: String, schemasDir: File, currentFile: String): JSONObject {
        var node = JSONObject(File(schemasDir, refFile(ref, currentFile)).readText())
        ref.substringAfter('#', "").split('/').filter { it.isNotEmpty() }.forEach { segment ->
            node = node.getJSONObject(segment)
        }
        return node
    }

    private fun collectJsonPaths(value: Any, prefix: String, into: MutableSet<String>) {
        when (value) {
            is JSONObject -> for (key in value.keys()) {
                val path = "$prefix/$key"
                into += path
                collectJsonPaths(value.get(key), path, into)
            }
            is JSONArray -> for (index in 0 until value.length()) {
                collectJsonPaths(value.get(index), "$prefix[]", into)
            }
        }
    }

    private fun schemasDir(): File {
        // The Gradle test working directory is the module directory; walk up to
        // the repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/schemas")
            if (File(candidate, "route-planner-input.schema.json").isFile) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/schemas/route-planner-input.schema.json")
    }
}
