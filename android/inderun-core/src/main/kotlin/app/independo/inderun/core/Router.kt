package app.independo.inderun.core

import app.independo.inderun.contracts.ExecutionPolicy
import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.TaskRequest

data class RouteSelection(
    val provider: ProviderAdapter,
    val explanation: String
)

class Router private constructor(
    private val registry: ProviderRegistry,
    private val planner: RoutePlanner
) {
    constructor(registry: ProviderRegistry) : this(registry, SharedCoreRoutePlanner)

    suspend fun selectRoute(
        request: TaskRequest,
        hostServices: HostServices
    ): RouteSelection {
        val online = hostServices.connectivity.isOnline()
        val snapshots = collectProviderSnapshots(hostServices)

        planner.planRoute(
            buildSharedPlannerInput(
                request = request,
                online = online,
                snapshots = snapshots
            )
        )?.let { routePlan ->
            return selectFromSharedPlan(request, snapshots, routePlan)
        }

        return selectLegacyRoute(request, snapshots, online)
    }

    private suspend fun collectProviderSnapshots(hostServices: HostServices): List<ProviderSnapshot> {
        return registry.list()
            .map { provider ->
                ProviderSnapshot(
                    provider = provider,
                    descriptor = provider.describe(),
                    capabilities = provider.capabilities(hostServices)
                )
            }
            .sortedBy { snapshot -> snapshot.descriptor.id }
    }

    private fun selectFromSharedPlan(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        routePlan: SharedPlannerRoutePlan
    ): RouteSelection {
        routePlan.selectedProviderId?.let { selectedProviderId ->
            snapshots.firstOrNull { snapshot -> snapshot.descriptor.id == selectedProviderId }?.let { snapshot ->
                return RouteSelection(
                    provider = snapshot.provider,
                    explanation = routePlan.explanation.summary
                )
            }
        }

        val message = routePlan.explanation.summary
        when (routePlan.failureCode) {
            FailureCode.Offline -> throw createOffline(message)
            FailureCode.CapabilityMismatch -> throw createCapabilityMismatch(message)
            FailureCode.Unavailable -> throw createUnavailable(message)
            else -> {
                when (request.policy.execution) {
                    ExecutionPolicy.ON_DEVICE -> throw createCapabilityMismatch(message)
                    ExecutionPolicy.CLOUD -> throw createUnavailable(message)
                }
            }
        }
    }

    private fun selectLegacyRoute(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        online: Boolean
    ): RouteSelection {
        val taskKind = request.task.kind.rawValue
        val taskCandidates = snapshots.filter { snapshot ->
            snapshot.descriptor.tasks.contains(taskKind) && snapshot.descriptor.supports.run
        }

        return when (request.policy.execution) {
            ExecutionPolicy.ON_DEVICE -> {
                val localCandidates = taskCandidates.filter { snapshot ->
                    snapshot.descriptor.type == ProviderDescriptor.ProviderType.local
                }

                if (localCandidates.isEmpty()) {
                    throw createCapabilityMismatch(
                        "Capability mismatch: no on-device provider found supporting task '$taskKind'."
                    )
                }

                val selected = localCandidates.firstOrNull { snapshot -> snapshot.capabilities.available }
                if (selected != null) {
                    RouteSelection(
                        provider = selected.provider,
                        explanation = "Selected on-device provider '${selected.descriptor.id}' deterministically."
                    )
                } else {
                    throw createCapabilityMismatch(
                        "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
                    )
                }
            }

            ExecutionPolicy.CLOUD -> {
                if (!online) {
                    throw createOffline(
                        "Offline: cloud execution selected, but no network connection is available."
                    )
                }

                val cloudCandidates = taskCandidates.filter { snapshot ->
                    snapshot.descriptor.type == ProviderDescriptor.ProviderType.cloud
                }

                if (cloudCandidates.isEmpty()) {
                    throw createUnavailable(
                        "Unavailable: no cloud provider found supporting task '$taskKind'."
                    )
                }

                val selected = cloudCandidates.firstOrNull { snapshot -> snapshot.capabilities.available }
                if (selected != null) {
                    RouteSelection(
                        provider = selected.provider,
                        explanation = "Selected cloud provider '${selected.descriptor.id}' deterministically."
                    )
                } else {
                    throw createUnavailable(
                        "Unavailable: cloud execution selected, but no cloud provider is currently available."
                    )
                }
            }
        }
    }

    internal companion object {
        fun withPlanner(registry: ProviderRegistry, planner: RoutePlanner): Router {
            return Router(registry, planner)
        }
    }
}
