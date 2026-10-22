package app.independo.inderun.core

import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.ModelProfile
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.TaskRequest

/**
 * One provider in the planned chain, with the voice the plan bound it to (speech only).
 */
data class RouteCandidate(
    val provider: ProviderAdapter,
    /**
     * The voice this provider must use, chosen by the planner within the request's privacy
     * policy. Null when the task has no voice or the provider does not list its voices.
     */
    val voice: ProviderVoice? = null,
)

data class RouteSelection(
    val provider: ProviderAdapter,
    val fallbackProviders: List<ProviderAdapter>,
    val routePlan: SharedPlannerRoutePlan,
    val explanation: String,
    /** The whole chain in attempt order ([provider] first, then [fallbackProviders]), each with its bound voice. */
    val candidates: List<RouteCandidate>,
)

class Router private constructor(
    private val registry: ProviderRegistry,
    private val planner: RoutePlanner,
) {
    constructor(registry: ProviderRegistry) : this(registry, SharedCoreRoutePlanner)

    /**
     * Plans a route for [request].
     *
     * [interactionMode] is a planning input, not a filter applied to the result:
     * providers that cannot satisfy the requested mode are rejected during
     * planning with their own normalized reason, so a `stream` request and a
     * `run` request over the same registry may legitimately produce different
     * provider chains while remaining under identical privacy, locality and
     * availability constraints.
     */
    suspend fun selectRoute(
        request: TaskRequest,
        hostServices: HostServices,
        interactionMode: InteractionMode = InteractionMode.Run,
        modelProfile: ModelProfile? = null,
    ): RouteSelection {
        val online = hostServices.connectivity.isOnline()
        val snapshots = collectProviderSnapshots(hostServices)

        val routePlan = try {
            planner.planRoute(
                buildSharedPlannerInput(
                    request = request,
                    online = online,
                    snapshots = snapshots,
                    interactionMode = interactionMode,
                    modelProfile = modelProfile,
                ),
            )
        } catch (failure: RoutePlannerUnavailableException) {
            // There is no second planner: a plan that cannot be produced is an
            // internal failure, not a reason to route by a different rule set.
            throw createInternal(
                message = "Route planner unavailable (${failure.reason.value}).",
                details = mapOf("plannerUnavailableReason" to failure.reason.value),
            )
        }

        return selectFromRoutePlan(snapshots, routePlan)
    }

    private suspend fun collectProviderSnapshots(hostServices: HostServices): List<ProviderSnapshot> = registry.list()
        .map { provider ->
            ProviderSnapshot(
                provider = provider,
                descriptor = provider.describe(),
                capabilities = provider.capabilities(hostServices),
            )
        }

    private fun selectFromRoutePlan(
        snapshots: List<ProviderSnapshot>,
        routePlan: SharedPlannerRoutePlan,
    ): RouteSelection {
        routePlan.selectedProviderId?.let { selectedProviderId ->
            // Each planned snapshot keeps the voice its candidate was bound to.
            val orderedSnapshots = routePlan.candidates.mapNotNull { candidate ->
                snapshots.firstOrNull { snapshot -> snapshot.descriptor.id == candidate.providerId }
                    ?.let { it to candidate.voice }
            }.ifEmpty {
                snapshots.firstOrNull { snapshot -> snapshot.descriptor.id == selectedProviderId }
                    ?.let { listOf(it to null) }
                    .orEmpty()
            }

            val selected = orderedSnapshots.firstOrNull { (snapshot) ->
                snapshot.descriptor.id == selectedProviderId
            } ?: orderedSnapshots.firstOrNull()

            if (selected != null) {
                val candidates = (listOf(selected) + orderedSnapshots.drop(1)).map { (snapshot, voice) ->
                    RouteCandidate(provider = snapshot.provider, voice = voice)
                }
                return RouteSelection(
                    provider = selected.first.provider,
                    fallbackProviders = orderedSnapshots.drop(1).map { (snapshot) -> snapshot.provider },
                    routePlan = routePlan,
                    explanation = routePlan.explanation.summary,
                    candidates = candidates,
                )
            }
        }

        throw routePlanFailure(routePlan)
    }

    /**
     * Routing failure throws before any `route_decided` telemetry is emitted, so the plan's
     * diagnostics are attached to the exception -- that is the only channel through which a
     * caller learns *why* each provider was rejected.
     */
    private fun routePlanFailure(routePlan: SharedPlannerRoutePlan): Throwable {
        val message = routePlan.explanation.summary
        val details = routePlanFailureDetails(routePlan)
        return when (routePlan.failureCode) {
            FailureCode.Offline -> createOffline(message, details = details)
            FailureCode.Unavailable -> createUnavailable(message, details = details)
            FailureCode.CapabilityMismatch, null -> createCapabilityMismatch(message, details = details)
        }
    }

    /**
     * Flattens the plan's typed diagnostics into the same JSON shape the Web SDK attaches, so a
     * caller reads one contract across platforms.
     */
    private fun routePlanFailureDetails(routePlan: SharedPlannerRoutePlan): Map<String, Any?> = buildMap {
        routePlan.failureCode?.let { put("failureCode", it.rawValue) }
        put(
            "rejectedProviders",
            routePlan.rejectedProviders.map { rejected ->
                mapOf(
                    "providerId" to rejected.providerId,
                    "reasons" to rejected.reasons.map { reason ->
                        mapOf("code" to reasonCodeValue(reason.code), "message" to reason.message)
                    },
                )
            },
        )
    }

    internal companion object {
        fun withPlanner(registry: ProviderRegistry, planner: RoutePlanner): Router = Router(registry, planner)
    }
}

internal data class ProviderSnapshot(
    val provider: ProviderAdapter,
    val descriptor: ProviderDescriptor,
    val capabilities: ProviderDynamicCapabilities,
)
