package app.independo.inderun.core

import app.independo.inderun.contracts.Capabilities
import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.Constraints
import app.independo.inderun.contracts.Descriptor
import app.independo.inderun.contracts.DescriptorType
import app.independo.inderun.contracts.ExecutionPolicy
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.Preferences
import app.independo.inderun.contracts.Provider
import app.independo.inderun.contracts.Reason
import app.independo.inderun.contracts.RejectedProvider
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.RoutePlannerInput
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.Supports
import app.independo.inderun.contracts.TaskRequest
import org.json.JSONArray
import org.json.JSONObject

internal typealias SharedPlannerInput = RoutePlannerInput
internal typealias SharedPlannerRoutePlan = RoutePlan
internal typealias SharedPlannerTask = RoutePlannerInputTask
internal typealias SharedPlannerConstraints = Constraints
internal typealias SharedPlannerPreferences = Preferences
internal typealias SharedPlannerProviderInput = Provider
internal typealias SharedPlannerProviderDescriptor = Descriptor
internal typealias SharedPlannerProviderSupports = Supports
internal typealias SharedPlannerCapabilities = Capabilities
internal typealias SharedPlannerExplanation = Explanation
internal typealias SharedPlannerRejectedProvider = RejectedProvider
internal typealias SharedPlannerRejectedReason = Reason
internal typealias SharedPlannerReasonCode = Code

internal interface RoutePlanner {
    fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan?
}

internal object SharedCoreRoutePlanner : RoutePlanner {
    @Volatile
    private var nativeLoaded = false

    override fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan? {
        if (!ensureLoaded()) {
            return null
        }

        val outputJson = runCatching {
            planRouteJsonNative(input.toJson())
        }.getOrNull() ?: return null

        return parseSharedPlannerRoutePlan(outputJson)
    }

    @JvmStatic
    private external fun planRouteJsonNative(inputJson: String): String

    @Synchronized
    private fun ensureLoaded(): Boolean {
        if (nativeLoaded) {
            return true
        }

        nativeLoaded = runCatching {
            val explicitPath = System.getProperty("inderun.routeCoreLibPath")
                ?: System.getenv("INDERUN_ROUTE_CORE_LIB_PATH")
            if (!explicitPath.isNullOrBlank()) {
                System.load(explicitPath)
            } else {
                System.loadLibrary("inderun_route_core")
            }
            true
        }.getOrDefault(false)

        return nativeLoaded
    }
}

internal fun buildSharedPlannerInput(
    request: TaskRequest,
    online: Boolean,
    snapshots: List<ProviderSnapshot>
): SharedPlannerInput {
    return SharedPlannerInput(
        constraints = SharedPlannerConstraints(
            executionTarget = request.policy.execution,
            networkOnline = online
        ),
        preferences = SharedPlannerPreferences(preferredProviderIds = emptyList()),
        providers = snapshots.map { snapshot ->
            SharedPlannerProviderInput(
                descriptor = SharedPlannerProviderDescriptor(
                    id = snapshot.descriptor.id,
                    supports = SharedPlannerProviderSupports(run = snapshot.descriptor.supports.run),
                    tasks = snapshot.descriptor.tasks,
                    type = when (snapshot.descriptor.type) {
                        ProviderDescriptor.ProviderType.local -> DescriptorType.Local
                        ProviderDescriptor.ProviderType.edge -> DescriptorType.Edge
                        ProviderDescriptor.ProviderType.cloud -> DescriptorType.Cloud
                    }
                ),
                capabilities = SharedPlannerCapabilities(
                    available = snapshot.capabilities.available,
                    reason = snapshot.capabilities.reason
                )
            )
        },
        task = SharedPlannerTask(kind = request.task.kind.rawValue)
    )
}

internal data class ProviderSnapshot(
    val provider: ProviderAdapter,
    val descriptor: ProviderDescriptor,
    val capabilities: ProviderDynamicCapabilities
)

private fun SharedPlannerInput.toJson(): String {
    return JSONObject()
        .put("task", JSONObject().put("kind", task.kind))
        .put(
            "constraints",
            JSONObject()
                .put("executionTarget", executionTargetValue(constraints.executionTarget))
                .put("networkOnline", constraints.networkOnline)
        )
        .put(
            "preferences",
            JSONObject().put(
                "preferredProviderIds",
                JSONArray(preferences.preferredProviderIds)
            )
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
                                .put(
                                    "supports",
                                    JSONObject().put("run", provider.descriptor.supports.run)
                                )
                                .put("tasks", JSONArray(provider.descriptor.tasks))
                        )
                        .put(
                            "capabilities",
                            JSONObject()
                                .put("available", provider.capabilities.available)
                                .put("reason", provider.capabilities.reason)
                        )
                }
            )
        )
        .toString()
}

private fun parseSharedPlannerRoutePlan(json: String): SharedPlannerRoutePlan {
    val root = JSONObject(json)
    val explanation = root.getJSONObject("explanation")
    return SharedPlannerRoutePlan(
        candidates = root.optJSONArray("candidates").toCandidates(),
        explanation = SharedPlannerExplanation(
            selectedProviderId = explanation.optString("selectedProviderId").takeUnless { it.isEmpty() },
            summary = explanation.optString("summary")
        ),
        failureCode = root.optString("failureCode").takeUnless { it.isEmpty() }?.let(::parseFailureCode),
        fallbackProviderIds = root.optJSONArray("fallbackProviderIds").toStringList(),
        rejectedProviders = root.optJSONArray("rejectedProviders").toRejectedProviders(),
        selectedProviderId = root.optString("selectedProviderId").takeUnless { it.isEmpty() }
    )
}

private fun parseFailureCode(value: String): FailureCode {
    return when (value) {
        "capability_mismatch" -> FailureCode.CapabilityMismatch
        "offline" -> FailureCode.Offline
        "unavailable" -> FailureCode.Unavailable
        else -> throw IllegalArgumentException("Unknown FailureCode: $value")
    }
}

private fun descriptorTypeValue(value: DescriptorType): String {
    return when (value) {
        DescriptorType.Cloud -> "cloud"
        DescriptorType.Edge -> "edge"
        DescriptorType.Local -> "local"
    }
}

private fun executionTargetValue(value: ExecutionPolicy): String {
    return value.rawValue
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
            providerId = candidate.getString("providerId")
        )
    }
}

private fun JSONArray?.toRejectedProviders(): List<SharedPlannerRejectedProvider> {
    if (this == null) return emptyList()
    return List(length()) { index ->
        val rejectedProvider = getJSONObject(index)
        SharedPlannerRejectedProvider(
            providerId = rejectedProvider.getString("providerId"),
            reasons = rejectedProvider.getJSONArray("reasons").toReasons()
        )
    }
}

private fun JSONArray.toReasons(): List<SharedPlannerRejectedReason> {
    return List(length()) { index ->
        val reason = getJSONObject(index)
        SharedPlannerRejectedReason(
            code = parseReasonCode(reason.getString("code")),
            message = reason.getString("message")
        )
    }
}

private fun parseReasonCode(value: String): SharedPlannerReasonCode {
    return when (value) {
        "capability_unavailable" -> SharedPlannerReasonCode.CapabilityUnavailable
        "execution_target_mismatch" -> SharedPlannerReasonCode.ExecutionTargetMismatch
        "offline" -> SharedPlannerReasonCode.Offline
        "run_not_supported" -> SharedPlannerReasonCode.RunNotSupported
        "task_not_supported" -> SharedPlannerReasonCode.TaskNotSupported
        else -> throw IllegalArgumentException("Unknown ReasonCode: $value")
    }
}
