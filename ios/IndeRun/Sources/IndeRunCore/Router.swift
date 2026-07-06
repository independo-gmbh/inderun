import Foundation
import IndeRunContracts

public struct RouteSelection: Sendable {
    public let provider: any ProviderAdapter
    public let fallbackProviders: [any ProviderAdapter]
    public let routePlan: RoutePlan
    public let explanation: String

    public init(
        provider: any ProviderAdapter,
        fallbackProviders: [any ProviderAdapter],
        routePlan: RoutePlan,
        explanation: String
    ) {
        self.provider = provider
        self.fallbackProviders = fallbackProviders
        self.routePlan = routePlan
        self.explanation = explanation
    }
}

public final class Router: Sendable {
    private let registry: ProviderRegistry
    private let planner: any RoutePlanning

    public init(registry: ProviderRegistry) {
        self.registry = registry
        self.planner = SharedCoreRoutePlanner.shared
    }

    init(registry: ProviderRegistry, planner: any RoutePlanning) {
        self.registry = registry
        self.planner = planner
    }

    public func selectRoute(
        request: TaskRequest,
        hostServices: HostServices
    ) async throws -> RouteSelection {
        let online = await hostServices.connectivity.isOnline()
        let snapshots = await collectProviderSnapshots(hostServices: hostServices)
        let planInput = buildSharedPlannerInput(
            request: request,
            online: online,
            snapshots: snapshots
        )

        if let routePlan = planner.planRoute(input: planInput) {
            return try selectFromRoutePlan(snapshots: snapshots, routePlan: routePlan)
        }

        return try selectFallbackRoute(request: request, snapshots: snapshots, networkOnline: online)
    }

    private func collectProviderSnapshots(hostServices: HostServices) async -> [ProviderSnapshot] {
        var snapshots = [ProviderSnapshot]()

        for provider in registry.list() {
            snapshots.append(
                ProviderSnapshot(
                    provider: provider,
                    descriptor: provider.describe(),
                    capabilities: await provider.capabilities(host: hostServices)
                )
            )
        }

        return snapshots.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    private func selectFromRoutePlan(
        snapshots: [ProviderSnapshot],
        routePlan: RoutePlan
    ) throws -> RouteSelection {
        guard routePlan.selectedProviderId != nil else {
            throw routePlanFailure(routePlan)
        }

        return try buildSelectionFromRoutePlan(snapshots: snapshots, routePlan: routePlan)
    }

    private func selectFallbackRoute(
        request: TaskRequest,
        snapshots: [ProviderSnapshot],
        networkOnline: Bool
    ) throws -> RouteSelection {
        let plan: RoutePlan = createFallbackPlan(request: request, snapshots: snapshots, networkOnline: networkOnline)
        guard plan.selectedProviderId != nil else {
            throw routePlanFailure(plan)
        }

        return try buildSelectionFromRoutePlan(snapshots: snapshots, routePlan: plan)
    }

    private func buildSelectionFromRoutePlan(
        snapshots: [ProviderSnapshot],
        routePlan: RoutePlan
    ) throws -> RouteSelection {
        let orderedSnapshots = routePlan.candidates.compactMap { candidate in
            snapshots.first(where: { $0.descriptor.id == candidate.providerId })
        }

        guard let selectedId = routePlan.selectedProviderId ?? orderedSnapshots.first?.descriptor.id,
              let selected = snapshots.first(where: { $0.descriptor.id == selectedId }) else {
            throw createInternal(message: "Route plan selected a provider that is no longer registered.")
        }

        return RouteSelection(
            provider: selected.provider,
            fallbackProviders: orderedSnapshots.filter { $0.descriptor.id != selectedId }.map { $0.provider },
            routePlan: routePlan,
            explanation: routePlan.explanation.summary
        )
    }

    private func createFallbackPlan(
        request: TaskRequest,
        snapshots: [ProviderSnapshot],
        networkOnline: Bool
    ) -> RoutePlan {
        let planInput = buildSharedPlannerInput(request: request, online: networkOnline, snapshots: snapshots)
        let eligible = snapshots.filter {
            $0.descriptor.tasks.contains(planInput.task.kind) && $0.descriptor.supports.run
        }

        let selected = eligible.first { snapshot in
            let descriptor = snapshot.descriptor
            let constraints = planInput.constraints
            let isPrivate = descriptor.privacy?.dataLeavesDevice == false || descriptor.type != .cloud

            if constraints.cloud == .forbidden && descriptor.type == .cloud { return false }
            if constraints.cloud == .cloudRequired && descriptor.type != .cloud { return false }
            if constraints.privacy == .localRequired && !isPrivate { return false }
            if constraints.privacy == .cloudRequired && descriptor.type != .cloud { return false }
            if !networkOnline && descriptor.type == .cloud { return false }
            return snapshot.capabilities.available
        }

        let ordered: [ProviderSnapshot] = selected.map { selectedSnapshot -> [ProviderSnapshot] in
            [selectedSnapshot] + eligible.filter { $0.descriptor.id != selectedSnapshot.descriptor.id }
        } ?? []
        if ordered.isEmpty {
            let failureCode: FailureCode? = !networkOnline
                ? .offline
                : (planInput.constraints.cloud == .cloudRequired || planInput.constraints.privacy == .cloudRequired)
                ? .unavailable
                : .capabilityMismatch

            return RoutePlan(
                candidates: [],
                explanation: Explanation(
                    selectedProviderId: nil,
                    summary: "No eligible provider found for the current routing constraints."
                ),
                failureCode: failureCode,
                fallbackProviderIds: [],
                rejectedProviders: [],
                selectedProviderId: nil
            )
        }

        return RoutePlan(
            candidates: ordered.enumerated().map { index, snapshot in
                Candidate(order: index, providerId: snapshot.descriptor.id)
            },
            explanation: Explanation(
                selectedProviderId: ordered.first?.descriptor.id,
                summary: "Selected provider '\(ordered.first?.descriptor.id ?? "")' deterministically "
                    + "from \(ordered.count) eligible candidate(s)."
            ),
            failureCode: nil,
            fallbackProviderIds: ordered.dropFirst().map { $0.descriptor.id },
            rejectedProviders: [],
            selectedProviderId: ordered.first?.descriptor.id
        )
    }

    private func routePlanFailure(_ routePlan: RoutePlan) -> Error {
        let message = routePlan.explanation.summary
        switch routePlan.failureCode {
        case .some(.offline):
            return createOffline(message: message)
        case .some(.unavailable):
            return createUnavailable(message: message)
        case .some(.capabilityMismatch), .none:
            return createCapabilityMismatch(message: message)
        }
    }
}

private func buildSharedPlannerInput(
    request: TaskRequest,
    online: Bool,
    snapshots: [ProviderSnapshot]
) -> SharedPlannerInput {
    let constraints = request.constraints
    let preferences = request.preferences

    return SharedPlannerInput(
        constraints: SharedPlannerConstraints(
            cloud: constraints?.cloud,
            networkOnline: online,
            privacy: constraints?.privacy
        ),
        preferences: SharedPlannerPreferences(
            optimizeFor: preferences?.optimizeFor
        ),
        providers: snapshots.map { snapshot in
            SharedPlannerProviderInput(
                capabilities: SharedPlannerCapabilities(
                    available: snapshot.capabilities.available,
                    reason: nil
                ),
                descriptor: SharedPlannerProviderDescriptor(
                    id: snapshot.descriptor.id,
                    privacy: snapshot.descriptor.privacy.map { privacy in
                        PrivacyClass(
                            dataLeavesDevice: privacy.dataLeavesDevice,
                            regions: privacy.regions
                        )
                    },
                    supports: SharedPlannerProviderSupports(run: snapshot.descriptor.supports.run),
                    tasks: snapshot.descriptor.tasks,
                    type: descriptorType(from: snapshot.descriptor.type)
                )
            )
        },
        task: SharedPlannerTask(kind: request.task.kind.rawValue)
    )
}

private struct ProviderSnapshot: Sendable {
    let provider: any ProviderAdapter
    let descriptor: ProviderDescriptor
    let capabilities: ProviderDynamicCapabilities
}

private func descriptorType(from value: ProviderDescriptor.ProviderType) -> DescriptorType {
    switch value {
    case .local:
        return .local
    case .edge:
        return .edge
    case .cloud:
        return .cloud
    }
}
