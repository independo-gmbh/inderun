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

        let routePlan: SharedPlannerRoutePlan
        do {
            routePlan = try planner.planRoute(input: planInput)
        } catch let failure as RoutePlannerUnavailable {
            // There is no second planner to degrade to: routing is the shared Rust
            // core's semantics or nothing. Failing here keeps provider selection
            // identical across platforms rather than forking it whenever the core
            // cannot answer.
            throw createInternal(
                message: "Route planner unavailable (\(failure.reason.rawValue)).",
                details: ["plannerUnavailableReason": JSONAny(failure.reason.rawValue)]
            )
        }

        return try selectFromRoutePlan(snapshots: snapshots, routePlan: routePlan)
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

        // Registration order is passed through untouched: the shared planner ranks
        // candidates itself and tie-breaks by provider id, so sorting here would
        // only assert an ordering the planner is free to ignore.
        return snapshots
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
