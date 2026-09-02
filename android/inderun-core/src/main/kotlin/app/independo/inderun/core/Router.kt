package app.independo.inderun.core

import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.InteractionMode
import app.independo.inderun.contracts.TaskRequest

data class RouteSelection(
    val provider: ProviderAdapter,
    val fallbackProviders: List<ProviderAdapter>,
    val routePlan: SharedPlannerRoutePlan,
    val explanation: String,
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
            val orderedSnapshots = routePlan.candidates.mapNotNull { candidate ->
                snapshots.firstOrNull { snapshot -> snapshot.descriptor.id == candidate.providerId }
            }.ifEmpty {
                snapshots.firstOrNull { snapshot -> snapshot.descriptor.id == selectedProviderId }
                    ?.let { listOf(it) }
                    .orEmpty()
            }

            val selected = orderedSnapshots.firstOrNull { snapshot ->
                snapshot.descriptor.id == selectedProviderId
            } ?: orderedSnapshots.firstOrNull()

            if (selected != null) {
                return RouteSelection(
                    provider = selected.provider,
                    fallbackProviders = orderedSnapshots.drop(1).map { it.provider },
                    routePlan = routePlan,
                    explanation = routePlan.explanation.summary,
                )
            }
        }

        throw routePlanFailure(routePlan)
    }

    private fun routePlanFailure(routePlan: SharedPlannerRoutePlan): Throwable {
        val message = routePlan.explanation.summary
        return when (routePlan.failureCode) {
            FailureCode.Offline -> createOffline(message)
            FailureCode.Unavailable -> createUnavailable(message)
            FailureCode.CapabilityMismatch, null -> createCapabilityMismatch(message)
        }
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
