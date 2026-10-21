package app.independo.inderun.core

import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.ModelProfile
import app.independo.inderun.contracts.Provider
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.Reason
import app.independo.inderun.contracts.RejectedProvider
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.RoutePlannerInput
import app.independo.inderun.contracts.RoutePlannerInputConstraints
import app.independo.inderun.contracts.RoutePlannerInputPreferences
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.TaskRequest
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal typealias SharedPlannerInput = RoutePlannerInput
internal typealias SharedPlannerRoutePlan = RoutePlan
internal typealias SharedPlannerTask = RoutePlannerInputTask
internal typealias SharedPlannerConstraints = RoutePlannerInputConstraints
internal typealias SharedPlannerPreferences = RoutePlannerInputPreferences
internal typealias SharedPlannerProviderInput = Provider
internal typealias SharedPlannerExplanation = Explanation
internal typealias SharedPlannerRejectedProvider = RejectedProvider
internal typealias SharedPlannerRejectedReason = Reason
internal typealias SharedPlannerReasonCode = Code

internal interface RoutePlanner {
    fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan
}

/**
 * Why the shared route core could not produce a plan. There is no second planner
 * behind it, so each of these is a routing failure the caller sees rather than a
 * signal to fall back — the vocabulary exists so the failure names itself.
 */
internal enum class RoutePlannerUnavailableReason(val value: String) {
    /** The native library could not be loaded; the AAR is missing its jniLibs. */
    LibraryUnavailable("library_unavailable"),

    /** The JNI call itself failed. Planner-level errors arrive as a plan, not as a throw. */
    PlanFailed("plan_failed"),

    /** The core returned JSON this build cannot read — a contract skew between the two. */
    InvalidPlanShape("invalid_plan_shape"),
}

internal class RoutePlannerUnavailableException(
    val reason: RoutePlannerUnavailableReason,
    cause: Throwable? = null,
) : IllegalStateException("Route planner unavailable (${reason.value}).", cause)

internal object SharedCoreRoutePlanner : RoutePlanner {
    @Volatile
    private var nativeLoaded = false

    override fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan {
        ensureLoaded()

        // Serialized outside the try: a failure here is a bug in `toJson`, and
        // mislabelling it as a JNI failure would send the reader to the wrong
        // side of the boundary.
        val inputJson = input.toJson()

        // Only a JNI-level failure throws: the core answers a malformed input with
        // a plan carrying `failureCode`, which is a routing outcome, not this.
        val outputJson = try {
            planRouteJsonNative(inputJson)
        } catch (error: RuntimeException) {
            throw RoutePlannerUnavailableException(RoutePlannerUnavailableReason.PlanFailed, error)
        }

        return try {
            parseSharedPlannerRoutePlan(outputJson)
        } catch (error: JSONException) {
            throw RoutePlannerUnavailableException(RoutePlannerUnavailableReason.InvalidPlanShape, error)
        }
    }

    @JvmStatic
    private external fun planRouteJsonNative(inputJson: String): String

    /**
     * The library is packaged into the AAR as jniLibs (see
     * android/inderun-core/build.gradle.kts), and the JVM unit tests get a
     * host build on `java.library.path`, so both reach it by the same
     * `System.loadLibrary` call. A failure here is a broken build, not a
     * degraded mode: it is raised rather than recorded.
     */
    @Synchronized
    private fun ensureLoaded() {
        if (nativeLoaded) {
            return
        }

        try {
            System.loadLibrary("inderun_route_core")
        } catch (error: UnsatisfiedLinkError) {
            throw RoutePlannerUnavailableException(
                RoutePlannerUnavailableReason.LibraryUnavailable,
                error,
            )
        }

        nativeLoaded = true
    }
}

internal fun buildSharedPlannerInput(
    request: TaskRequest,
    online: Boolean,
    snapshots: List<ProviderSnapshot>,
    interactionMode: InteractionMode = InteractionMode.Run,
    modelProfile: ModelProfile? = null,
): SharedPlannerInput {
    val constraints = request.constraints
    val preferences = request.preferences
    return SharedPlannerInput(
        interactionMode = interactionMode,
        modelProfile = modelProfile,
        constraints = SharedPlannerConstraints(
            privacy = constraints?.privacy,
            cloud = constraints?.cloud,
            networkOnline = online,
        ),
        preferences = SharedPlannerPreferences(
            optimizeFor = preferences?.optimizeFor,
        ),
        providers = snapshots.map { snapshot ->
            SharedPlannerProviderInput(
                descriptor = snapshot.descriptor,
                capabilities = streamingAwareCapabilities(snapshot),
            )
        },
        task = SharedPlannerTask(kind = request.task.kind.rawValue),
    )
}

/**
 * Folds the "declares streaming but does not implement it" check into the
 * dynamic capability the planner sees, so the mismatch is rejected during
 * planning with an explanation instead of surfacing as an unexplained failure
 * later. Mirrors `toSharedPlannerCapabilities` in the Web SDK's route planner.
 */
private fun streamingAwareCapabilities(snapshot: ProviderSnapshot): ProviderDynamicCapabilities {
    val declaresStreaming = snapshot.capabilities.streamingAvailable ?: snapshot.descriptor.supports.streaming
    val implementsStream = snapshot.provider is StreamingProviderAdapter
    val streamingUnavailableReason = snapshot.capabilities.streamingUnavailableReason
        ?: if (declaresStreaming && !implementsStream) {
            "Provider '${snapshot.descriptor.id}' declares streaming but does not implement stream()."
        } else {
            null
        }

    val streamingAvailable = declaresStreaming && implementsStream
    // Copy and override rather than rebuild, so a field added to the schema reaches the
    // planner without touching this function.
    return snapshot.capabilities.copy(
        streamingAvailable = streamingAvailable,
        streamingUnavailableReason = streamingUnavailableReason.takeUnless { streamingAvailable },
    )
}

/**
 * Hand-written serializer for the planner input. It is NOT regenerated with the
 * contracts, so every field added to `route-planner-input.schema.json` (or to the
 * provider schemas it references) has to be mirrored here — a field missing from this
 * object is silently dropped on the way into the shared core and forks this platform's
 * routing from the others. `SharedPlannerInputSerializationCoverageTest` walks the
 * schemas and fails when a property has no counterpart here.
 *
 * `JSONObject.put` with a null value removes the key, so an absent optional stays
 * absent — which matters for the tri-state dynamic capability flags.
 */
internal fun SharedPlannerInput.toJson(): String = JSONObject()
    .put("task", JSONObject().put("kind", task.kind))
    .put("interactionMode", interactionMode?.rawValue)
    .put(
        "constraints",
        JSONObject()
            .put("privacy", constraints.privacy?.rawValue)
            .put("cloud", constraints.cloud?.rawValue)
            .put("networkOnline", constraints.networkOnline),
    )
    .put(
        "preferences",
        JSONObject().put("optimizeFor", preferences.optimizeFor?.rawValue),
    )
    .put(
        "modelProfile",
        modelProfile?.let { profile ->
            JSONObject()
                .put("name", profile.name)
                .put("targetIds", JSONArray(profile.targetIds))
        },
    )
    .put(
        "providers",
        JSONArray(
            providers.map { provider ->
                JSONObject()
                    .put("descriptor", provider.descriptor.toPlannerJson())
                    .put("capabilities", provider.capabilities.toPlannerJson())
            },
        ),
    )
    .toString()

private fun ProviderDescriptor.toPlannerJson(): JSONObject = JSONObject()
    .put("id", id)
    .put("type", type.rawValue)
    .put("model", model)
    .put("transport", transport.rawValue)
    .put("streamingStyle", streamingStyle?.rawValue)
    .put(
        "supports",
        JSONObject()
            .put("run", supports.run)
            .put("streaming", supports.streaming)
            .put("realtime", supports.realtime)
            .put("tools", supports.tools)
            .put("reasoningEvents", supports.reasoningEvents)
            .put("structuredOutput", supports.structuredOutput)
            .put("multimodal", supports.multimodal),
    )
    .put("cancel", cancel.rawValue)
    .put("tasks", JSONArray(tasks))
    .put(
        "limits",
        limits?.let { limits ->
            JSONObject()
                .put("maxInputTokens", limits.maxInputTokens)
                .put("maxOutputTokens", limits.maxOutputTokens)
                .put("maxImageBytes", limits.maxImageBytes)
                .put("maxAudioSeconds", limits.maxAudioSeconds)
        },
    )
    .put(
        "privacy",
        privacy?.let { privacy ->
            JSONObject()
                .put("dataLeavesDevice", privacy.dataLeavesDevice)
                .put("regions", privacy.regions?.let { JSONArray(it) })
        },
    )

private fun ProviderDynamicCapabilities.toPlannerJson(): JSONObject = JSONObject()
    .put("available", available)
    .put("reason", reason)
    .put("streamingAvailable", streamingAvailable)
    .put("streamingUnavailableReason", streamingUnavailableReason)
    .put("cancellationAvailable", cancellationAvailable)

internal fun parseSharedPlannerRoutePlan(json: String): SharedPlannerRoutePlan {
    val root = JSONObject(json)
    val explanation = root.getJSONObject("explanation")
    return SharedPlannerRoutePlan(
        candidates = root.optJSONArray("candidates").toCandidates(),
        explanation = SharedPlannerExplanation(
            selectedProviderId = explanation.optString("selectedProviderId").takeUnless { it.isEmpty() },
            summary = explanation.optString("summary"),
        ),
        failureCode = root.optString("failureCode").takeUnless { it.isEmpty() }?.let(::parseFailureCode),
        fallbackProviderIds = root.optJSONArray("fallbackProviderIds").toStringList(),
        rejectedProviders = root.optJSONArray("rejectedProviders").toRejectedProviders(),
        selectedProviderId = root.optString("selectedProviderId").takeUnless { it.isEmpty() },
    )
}

/**
 * An unknown failure code from a newer native route core is folded into [FailureCode.Unavailable]
 * rather than thrown: the plan did fail, and the specific class is only a diagnostic refinement.
 */
private fun parseFailureCode(value: String): FailureCode = FailureCode.fromRawValue(value) ?: FailureCode.Unavailable

private fun JSONArray?.toStringList(): List<String> {
    if (this == null) return emptyList()
    return List(length()) { index -> getString(index) }
}

private fun JSONArray?.toCandidates(): List<Candidate> {
    if (this == null) return emptyList()
    return List(length()) { index ->
        val candidate = getJSONObject(index)
        Candidate(
            order = candidate.getLong("order"),
            providerId = candidate.getString("providerId"),
        )
    }
}

private fun JSONArray?.toRejectedProviders(): List<SharedPlannerRejectedProvider> {
    if (this == null) return emptyList()
    return List(length()) { index ->
        val rejectedProvider = getJSONObject(index)
        SharedPlannerRejectedProvider(
            providerId = rejectedProvider.getString("providerId"),
            reasons = rejectedProvider.getJSONArray("reasons").toReasons(),
        )
    }
}

/**
 * Reasons carrying a code this build does not know are dropped rather than fatal: the native
 * route core can be newer than the Kotlin core it is paired with, and an unrecognized diagnostic
 * must never turn a successful plan into a crash.
 */
private fun JSONArray.toReasons(): List<SharedPlannerRejectedReason> = (0 until length())
    .mapNotNull { index ->
        val reason = getJSONObject(index)
        parseReasonCode(reason.getString("code"))?.let { code ->
            SharedPlannerRejectedReason(
                code = code,
                message = reason.getString("message"),
            )
        }
    }

private fun parseReasonCode(value: String): SharedPlannerReasonCode? = when (value) {
    "capability_unavailable" -> SharedPlannerReasonCode.CapabilityUnavailable
    "cloud_constraint" -> SharedPlannerReasonCode.CloudConstraint
    "offline" -> SharedPlannerReasonCode.Offline
    "privacy_constraint" -> SharedPlannerReasonCode.PrivacyConstraint
    "run_not_supported" -> SharedPlannerReasonCode.RunNotSupported
    "streaming_not_supported" -> SharedPlannerReasonCode.StreamingNotSupported
    "streaming_unavailable" -> SharedPlannerReasonCode.StreamingUnavailable
    "task_not_supported" -> SharedPlannerReasonCode.TaskNotSupported
    "not_in_model_profile" -> SharedPlannerReasonCode.NotInModelProfile
    else -> null
}

/**
 * The inverse of [parseReasonCode], for putting a plan's diagnostics back on the wire when a
 * routing failure carries them out on an exception.
 *
 * [SharedPlannerReasonCode] is declared here rather than generated from the schemas, so this is
 * the one wire mapping still written by hand -- the generated contract enums carry a `rawValue`.
 * The `when` is exhaustive with no `else`: a new constant must be a compile error here, not a
 * silently wrong string.
 */
internal fun reasonCodeValue(value: SharedPlannerReasonCode): String = when (value) {
    SharedPlannerReasonCode.CapabilityUnavailable -> "capability_unavailable"
    SharedPlannerReasonCode.CloudConstraint -> "cloud_constraint"
    SharedPlannerReasonCode.Offline -> "offline"
    SharedPlannerReasonCode.PrivacyConstraint -> "privacy_constraint"
    SharedPlannerReasonCode.RunNotSupported -> "run_not_supported"
    SharedPlannerReasonCode.StreamingNotSupported -> "streaming_not_supported"
    SharedPlannerReasonCode.StreamingUnavailable -> "streaming_unavailable"
    SharedPlannerReasonCode.TaskNotSupported -> "task_not_supported"
    SharedPlannerReasonCode.NotInModelProfile -> "not_in_model_profile"
}
