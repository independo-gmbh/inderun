package app.independo.inderun.core

import app.independo.inderun.contracts.Cancel
import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Capabilities
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.Descriptor
import app.independo.inderun.contracts.DescriptorType
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.Provider
import app.independo.inderun.contracts.Reason
import app.independo.inderun.contracts.RejectedProvider
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.RoutePlannerInput
import app.independo.inderun.contracts.RoutePlannerInputConstraints
import app.independo.inderun.contracts.RoutePlannerInputPreferences
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.Supports
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
internal typealias SharedPlannerProviderDescriptor = Descriptor
internal typealias SharedPlannerProviderSupports = Supports
internal typealias SharedPlannerCapabilities = Capabilities
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
): SharedPlannerInput {
    val constraints = request.constraints
    val preferences = request.preferences
    return SharedPlannerInput(
        interactionMode = interactionMode,
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
                descriptor = SharedPlannerProviderDescriptor(
                    id = snapshot.descriptor.id,
                    supports = SharedPlannerProviderSupports(
                        run = snapshot.descriptor.supports.run,
                        streaming = snapshot.descriptor.supports.streaming,
                    ),
                    cancel = when (snapshot.descriptor.cancel) {
                        ProviderDescriptor.CancelSemantics.hard -> Cancel.Hard
                        ProviderDescriptor.CancelSemantics.soft -> Cancel.Soft
                        ProviderDescriptor.CancelSemantics.none -> Cancel.None
                    },
                    tasks = snapshot.descriptor.tasks,
                    type = when (snapshot.descriptor.type) {
                        ProviderDescriptor.ProviderType.local -> DescriptorType.Local
                        ProviderDescriptor.ProviderType.edge -> DescriptorType.Edge
                        ProviderDescriptor.ProviderType.cloud -> DescriptorType.Cloud
                    },
                    privacy = snapshot.descriptor.privacy?.let { privacy ->
                        app.independo.inderun.contracts.PrivacyClass(
                            dataLeavesDevice = privacy.dataLeavesDevice,
                            regions = privacy.regions,
                        )
                    },
                ),
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
private fun streamingAwareCapabilities(snapshot: ProviderSnapshot): SharedPlannerCapabilities {
    val declaresStreaming = snapshot.capabilities.streamingAvailable ?: snapshot.descriptor.supports.streaming
    val implementsStream = snapshot.provider is StreamingProviderAdapter
    val streamingUnavailableReason = snapshot.capabilities.streamingUnavailableReason
        ?: if (declaresStreaming && !implementsStream) {
            "Provider '${snapshot.descriptor.id}' declares streaming but does not implement stream()."
        } else {
            null
        }

    return SharedPlannerCapabilities(
        available = snapshot.capabilities.available,
        reason = snapshot.capabilities.reason,
        streamingAvailable = declaresStreaming && implementsStream,
        streamingUnavailableReason = streamingUnavailableReason,
        cancellationAvailable = snapshot.capabilities.cancellationAvailable,
    )
}

/**
 * Hand-written serializer for the planner input. It is NOT regenerated with the
 * contracts, so every field added to `route-planner-input.schema.json` has to be
 * mirrored here — a field missing from this object is silently dropped on the way
 * into the shared core and forks this platform's routing from the others.
 */
internal fun SharedPlannerInput.toJson(): String = JSONObject()
    .put("task", JSONObject().put("kind", task.kind))
    .put("interactionMode", interactionMode?.let(::interactionModeValue))
    .put(
        "constraints",
        JSONObject()
            .put("privacy", constraints.privacy?.let(::privacyValue))
            .put("cloud", constraints.cloud?.let(::cloudValue))
            .put("networkOnline", constraints.networkOnline),
    )
    .put(
        "preferences",
        JSONObject().put("optimizeFor", preferences.optimizeFor?.let(::optimizeForValue)),
    )
    .put(
        "providers",
        JSONArray(
            providers.map { provider ->
                JSONObject()
                    .put(
                        "descriptor",
                        JSONObject()
                            .put("id", provider.descriptor.id)
                            .put("type", descriptorTypeValue(provider.descriptor.type))
                            .put("cancel", provider.descriptor.cancel?.let(::cancelValue))
                            .put(
                                "privacy",
                                provider.descriptor.privacy?.let { privacy ->
                                    JSONObject()
                                        .put("dataLeavesDevice", privacy.dataLeavesDevice)
                                        .put(
                                            "regions",
                                            privacy.regions?.let { JSONArray(it) },
                                        )
                                },
                            )
                            .put(
                                "supports",
                                JSONObject()
                                    .put("run", provider.descriptor.supports.run)
                                    .put("streaming", provider.descriptor.supports.streaming),
                            )
                            .put("tasks", JSONArray(provider.descriptor.tasks)),
                    )
                    .put(
                        "capabilities",
                        JSONObject()
                            .put("available", provider.capabilities.available)
                            .put("reason", provider.capabilities.reason)
                            .put("streamingAvailable", provider.capabilities.streamingAvailable)
                            .put(
                                "streamingUnavailableReason",
                                provider.capabilities.streamingUnavailableReason,
                            )
                            .put(
                                "cancellationAvailable",
                                provider.capabilities.cancellationAvailable,
                            ),
                    )
            },
        ),
    )
    .toString()

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
private fun parseFailureCode(value: String): FailureCode = when (value) {
    "capability_mismatch" -> FailureCode.CapabilityMismatch
    "offline" -> FailureCode.Offline
    else -> FailureCode.Unavailable
}

private fun interactionModeValue(value: InteractionMode): String = when (value) {
    InteractionMode.Run -> "run"
    InteractionMode.Stream -> "stream"
}

private fun cancelValue(value: Cancel): String = when (value) {
    Cancel.Hard -> "hard"
    Cancel.Soft -> "soft"
    Cancel.None -> "none"
}

private fun descriptorTypeValue(value: DescriptorType): String = when (value) {
    DescriptorType.Cloud -> "cloud"
    DescriptorType.Edge -> "edge"
    DescriptorType.Local -> "local"
}

private fun cloudValue(value: app.independo.inderun.contracts.Cloud): String = when (value) {
    app.independo.inderun.contracts.Cloud.Allowed -> "allowed"
    app.independo.inderun.contracts.Cloud.Forbidden -> "forbidden"
    app.independo.inderun.contracts.Cloud.Required -> "required"
}

private fun privacyValue(value: app.independo.inderun.contracts.PrivacyEnum): String = when (value) {
    app.independo.inderun.contracts.PrivacyEnum.CloudAllowed -> "cloud_allowed"
    app.independo.inderun.contracts.PrivacyEnum.CloudRequired -> "cloud_required"
    app.independo.inderun.contracts.PrivacyEnum.LocalPreferred -> "local_preferred"
    app.independo.inderun.contracts.PrivacyEnum.LocalRequired -> "local_required"
}

private fun optimizeForValue(value: app.independo.inderun.contracts.OptimizeFor): String = when (value) {
    app.independo.inderun.contracts.OptimizeFor.Balanced -> "balanced"
    app.independo.inderun.contracts.OptimizeFor.Cost -> "cost"
    app.independo.inderun.contracts.OptimizeFor.Latency -> "latency"
    app.independo.inderun.contracts.OptimizeFor.Privacy -> "privacy"
}

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
    else -> null
}
