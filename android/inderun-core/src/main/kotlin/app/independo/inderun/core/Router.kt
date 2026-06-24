package app.independo.inderun.core

import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.TaskRequest

data class RouteSelection(
    val provider: ProviderAdapter,
    val fallbackProviders: List<ProviderAdapter>,
    val routePlan: SharedPlannerRoutePlan,
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
            return selectFromRoutePlan(snapshots, routePlan)
        }

        return selectFallbackRoute(request, snapshots, online)
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

    private fun selectFromRoutePlan(
        snapshots: List<ProviderSnapshot>,
        routePlan: SharedPlannerRoutePlan
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
                    explanation = routePlan.explanation.summary
                )
            }
        }

        throw routePlanFailure(routePlan)
    }

    private fun selectFallbackRoute(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        online: Boolean
    ): RouteSelection {
        val plan = createFallbackPlan(request, snapshots, online)
        return selectFromRoutePlan(snapshots, plan)
    }

    private fun createFallbackPlan(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        online: Boolean
    ): SharedPlannerRoutePlan {
        val planInput = buildSharedPlannerInput(
            request = request,
            online = online,
            snapshots = snapshots
        )

        val eligible = snapshots.filter { snapshot ->
            snapshot.descriptor.tasks.contains(planInput.task.kind) && snapshot.descriptor.supports.run
        }

        val selected = eligible.firstOrNull { snapshot ->
            val descriptor = snapshot.descriptor
            val constraints = planInput.constraints
            val isPrivate = descriptor.privacy?.dataLeavesDevice == false || descriptor.type != ProviderDescriptor.ProviderType.cloud

            if (constraints.cloud == app.independo.inderun.contracts.Cloud.Forbidden && descriptor.type == ProviderDescriptor.ProviderType.cloud) return@firstOrNull false
            if (constraints.cloud == app.independo.inderun.contracts.Cloud.Required && descriptor.type != ProviderDescriptor.ProviderType.cloud) return@firstOrNull false
            if (constraints.privacy == app.independo.inderun.contracts.PrivacyEnum.LocalRequired && !isPrivate) return@firstOrNull false
            if (constraints.privacy == app.independo.inderun.contracts.PrivacyEnum.CloudRequired && descriptor.type != ProviderDescriptor.ProviderType.cloud) return@firstOrNull false
            if (!online && descriptor.type == ProviderDescriptor.ProviderType.cloud) return@firstOrNull false
            snapshot.capabilities.available
        }

        val ordered = selected?.let { selectedSnapshot ->
            listOf(selectedSnapshot) + eligible.filter { it.descriptor.id != selectedSnapshot.descriptor.id }
        } ?: emptyList()

        if (ordered.isEmpty()) {
            val failureCode = when {
                !online -> FailureCode.Offline
                planInput.constraints.cloud == app.independo.inderun.contracts.Cloud.Required ||
                    planInput.constraints.privacy == app.independo.inderun.contracts.PrivacyEnum.CloudRequired -> FailureCode.Unavailable
                else -> FailureCode.CapabilityMismatch
            }

            return SharedPlannerRoutePlan(
                candidates = emptyList(),
                explanation = SharedPlannerExplanation(
                    summary = "No eligible provider found for the current routing constraints.",
                    selectedProviderId = null
                ),
                failureCode = failureCode,
                fallbackProviderIds = emptyList(),
                rejectedProviders = emptyList(),
                selectedProviderId = null
            )
        }

        return SharedPlannerRoutePlan(
            candidates = ordered.mapIndexed { index, snapshot ->
                Candidate(providerId = snapshot.descriptor.id, order = index.toLong())
            },
            explanation = SharedPlannerExplanation(
                summary = "Selected provider '${ordered.first().descriptor.id}' deterministically from ${ordered.size} eligible candidate(s).",
                selectedProviderId = ordered.first().descriptor.id
            ),
            failureCode = null,
            fallbackProviderIds = ordered.drop(1).map { it.descriptor.id },
            rejectedProviders = emptyList(),
            selectedProviderId = ordered.first().descriptor.id
        )
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
        fun withPlanner(registry: ProviderRegistry, planner: RoutePlanner): Router {
            return Router(registry, planner)
        }
    }
}

internal data class ProviderSnapshot(
    val provider: ProviderAdapter,
    val descriptor: ProviderDescriptor,
    val capabilities: ProviderDynamicCapabilities
)
