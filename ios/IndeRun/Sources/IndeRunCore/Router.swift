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

    /// Plans a route for `request`.
    ///
    /// `interactionMode` is a planning input, not a filter applied to the result:
    /// providers that cannot satisfy the requested mode are rejected during
    /// planning with their own normalized reason, so a `stream` request and a
    /// `run` request over the same registry may legitimately produce different
    /// provider chains while remaining under identical privacy, locality and
    /// availability constraints.
    public func selectRoute(
        request: TaskRequest,
        hostServices: HostServices,
        interactionMode: InteractionMode = .run
    ) async throws -> RouteSelection {
        let online = await hostServices.connectivity.isOnline()
        let snapshots = await collectProviderSnapshots(hostServices: hostServices)
        let planInput = buildSharedPlannerInput(
            request: request,
            online: online,
            snapshots: snapshots,
            interactionMode: interactionMode
        )

        if let routePlan = planner.planRoute(input: planInput) {
            return try selectFromRoutePlan(snapshots: snapshots, routePlan: routePlan)
        }

        return try selectFallbackRoute(
            request: request,
            snapshots: snapshots,
            networkOnline: online,
            interactionMode: interactionMode
        )
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
        networkOnline: Bool,
        interactionMode: InteractionMode
    ) throws -> RouteSelection {
        let plan: RoutePlan = createFallbackPlan(
            request: request,
            snapshots: snapshots,
            networkOnline: networkOnline,
            interactionMode: interactionMode
        )
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
        networkOnline: Bool,
        interactionMode: InteractionMode
    ) -> RoutePlan {
        let planInput = buildSharedPlannerInput(
            request: request,
            online: networkOnline,
            snapshots: snapshots,
            interactionMode: interactionMode
        )
        let wantsStream = interactionMode == .stream
        // Mode filtering mirrors the Rust route-core's `evaluate_provider`: the
        // run check is scoped to run mode, and stream mode requires both the
        // static declaration and the dynamic capability. This planner still does
        // not populate `rejectedProviders` — see issue #164.
        let eligible = snapshots.filter { snapshot in
            guard snapshot.descriptor.tasks.contains(planInput.task.kind) else { return false }
            guard let provider = planInput.providers.first(where: { $0.descriptor.id == snapshot.descriptor.id })
            else { return false }

            if wantsStream {
                return provider.descriptor.supports.streaming == true
                    && provider.capabilities.streamingAvailable != false
            }
            return snapshot.descriptor.supports.run
        }

        // Constraint-satisfying candidates only -- applied once, before picking a primary and
        // before building the fallback list, so a provider that violates the request's
        // cloud/privacy constraints (e.g. a cloud provider under `localRequired`) can never appear
        // as a fallback just because it happened to sit later in `eligible`. Mirrors the Rust
        // route-core's `plan_route`, which filters all candidates uniformly via `evaluate_provider`
        // before splitting them into selected + fallback.
        let constrained = eligible.filter { snapshot in
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

        let ordered: [ProviderSnapshot] = constrained.first.map { selectedSnapshot -> [ProviderSnapshot] in
            [selectedSnapshot] + constrained.filter { $0.descriptor.id != selectedSnapshot.descriptor.id }
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
                    summary: wantsStream
                        ? "No provider capable of streaming was found for task '\(planInput.task.kind)'."
                        : "No eligible provider found for the current routing constraints."
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
                summary: wantsStream
                    ? "Selected streaming provider '\(ordered.first?.descriptor.id ?? "")' deterministically "
                        + "from \(ordered.count) eligible candidate(s)."
                    : "Selected provider '\(ordered.first?.descriptor.id ?? "")' deterministically "
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
    snapshots: [ProviderSnapshot],
    interactionMode: InteractionMode
) -> SharedPlannerInput {
    let constraints = request.constraints
    let preferences = request.preferences

    return SharedPlannerInput(
        constraints: SharedPlannerConstraints(
            cloud: constraints?.cloud,
            networkOnline: online,
            privacy: constraints?.privacy
        ),
        interactionMode: interactionMode,
        preferences: SharedPlannerPreferences(
            optimizeFor: preferences?.optimizeFor
        ),
        providers: snapshots.map { snapshot in
            SharedPlannerProviderInput(
                capabilities: streamingAwareCapabilities(for: snapshot),
                descriptor: SharedPlannerProviderDescriptor(
                    cancel: cancelSemantics(from: snapshot.descriptor.cancel),
                    id: snapshot.descriptor.id,
                    privacy: snapshot.descriptor.privacy.map { privacy in
                        PrivacyClass(
                            dataLeavesDevice: privacy.dataLeavesDevice,
                            regions: privacy.regions
                        )
                    },
                    supports: SharedPlannerProviderSupports(
                        run: snapshot.descriptor.supports.run,
                        streaming: snapshot.descriptor.supports.streaming
                    ),
                    tasks: snapshot.descriptor.tasks,
                    type: descriptorType(from: snapshot.descriptor.type)
                )
            )
        },
        task: SharedPlannerTask(kind: request.task.kind.rawValue)
    )
}

/// Folds the "declares streaming but does not implement it" check into the
/// dynamic capability the planner sees, so the mismatch is rejected during
/// planning with an explanation instead of surfacing as an unexplained failure
/// later. Mirrors `toSharedPlannerCapabilities` in the Web SDK's route planner.
private func streamingAwareCapabilities(for snapshot: ProviderSnapshot) -> SharedPlannerCapabilities {
    let declaresStreaming = snapshot.capabilities.streamingAvailable
        ?? snapshot.descriptor.supports.streaming
    let implementsStream = snapshot.provider is any StreamingProviderAdapter
    let streamingAvailable = declaresStreaming && implementsStream
    let streamingUnavailableReason = snapshot.capabilities.streamingUnavailableReason
        ?? (declaresStreaming && !implementsStream
            ? "Provider '\(snapshot.descriptor.id)' declares streaming but does not implement stream()."
            : nil)

    return SharedPlannerCapabilities(
        available: snapshot.capabilities.available,
        cancellationAvailable: snapshot.capabilities.cancellationAvailable,
        reason: snapshot.capabilities.reason,
        streamingAvailable: streamingAvailable,
        streamingUnavailableReason: streamingUnavailableReason
    )
}

private struct ProviderSnapshot: Sendable {
    let provider: any ProviderAdapter
    let descriptor: ProviderDescriptor
    let capabilities: ProviderDynamicCapabilities
}

private func cancelSemantics(from value: ProviderDescriptor.CancelSemantics) -> Cancel {
    switch value {
    case .hard:
        return .hard
    case .soft:
        return .soft
    case .none:
        return .none
    }
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
