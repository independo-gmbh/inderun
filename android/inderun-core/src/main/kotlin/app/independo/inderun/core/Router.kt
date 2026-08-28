package app.independo.inderun.core

import app.independo.inderun.contracts.Candidate
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

        planner.planRoute(
            buildSharedPlannerInput(
                request = request,
                online = online,
                snapshots = snapshots,
                interactionMode = interactionMode,
            ),
        )?.let { routePlan ->
            return selectFromRoutePlan(snapshots, routePlan)
        }

        return selectFallbackRoute(request, snapshots, online, interactionMode)
    }

    private suspend fun collectProviderSnapshots(hostServices: HostServices): List<ProviderSnapshot> = registry.list()
        .map { provider ->
            ProviderSnapshot(
                provider = provider,
                descriptor = provider.describe(),
                capabilities = provider.capabilities(hostServices),
            )
        }
        .sortedBy { snapshot -> snapshot.descriptor.id }

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

    private fun selectFallbackRoute(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        online: Boolean,
        interactionMode: InteractionMode,
    ): RouteSelection {
        val plan = createFallbackPlan(request, snapshots, online, interactionMode)
        return selectFromRoutePlan(snapshots, plan)
    }

    private fun createFallbackPlan(
        request: TaskRequest,
        snapshots: List<ProviderSnapshot>,
        online: Boolean,
        interactionMode: InteractionMode,
    ): SharedPlannerRoutePlan {
        val planInput = buildSharedPlannerInput(
            request = request,
            online = online,
            snapshots = snapshots,
            interactionMode = interactionMode,
        )
        val wantsStream = interactionMode == InteractionMode.Stream

        // Mode filtering mirrors the Rust route-core's `evaluate_provider`: the
        // run check is scoped to run mode, and stream mode requires both the
        // static declaration and the dynamic capability. This planner still does
        // not populate `rejectedProviders` — see issue #164.
        val eligible = snapshots.filter { snapshot ->
            if (!snapshot.descriptor.tasks.contains(planInput.task.kind)) return@filter false
            if (!wantsStream) return@filter snapshot.descriptor.supports.run

            val projected = planInput.providers.firstOrNull { it.descriptor.id == snapshot.descriptor.id }
                ?: return@filter false
            projected.descriptor.supports.streaming == true &&
                projected.capabilities.streamingAvailable != false
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
                    summary = if (wantsStream) {
                        "No provider capable of streaming was found for task '${planInput.task.kind}'."
                    } else {
                        "No eligible provider found for the current routing constraints."
                    },
                    selectedProviderId = null,
                ),
                failureCode = failureCode,
                fallbackProviderIds = emptyList(),
                rejectedProviders = emptyList(),
                selectedProviderId = null,
            )
        }

        return SharedPlannerRoutePlan(
            candidates = ordered.mapIndexed { index, snapshot ->
                Candidate(providerId = snapshot.descriptor.id, order = index.toLong())
            },
            explanation = SharedPlannerExplanation(
                summary = if (wantsStream) {
                    "Selected streaming provider '${ordered.first().descriptor.id}' deterministically " +
                        "from ${ordered.size} eligible candidate(s)."
                } else {
                    "Selected provider '${ordered.first().descriptor.id}' deterministically " +
                        "from ${ordered.size} eligible candidate(s)."
                },
                selectedProviderId = ordered.first().descriptor.id,
            ),
            failureCode = null,
            fallbackProviderIds = ordered.drop(1).map { it.descriptor.id },
            rejectedProviders = emptyList(),
            selectedProviderId = ordered.first().descriptor.id,
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
        fun withPlanner(registry: ProviderRegistry, planner: RoutePlanner): Router = Router(registry, planner)
    }
}

internal data class ProviderSnapshot(
    val provider: ProviderAdapter,
    val descriptor: ProviderDescriptor,
    val capabilities: ProviderDynamicCapabilities,
)
