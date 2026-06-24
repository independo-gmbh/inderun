import Foundation
import IndeRunContracts

public struct RouteSelection: Sendable {
    public let provider: any ProviderAdapter
    public let explanation: String
    
    public init(provider: any ProviderAdapter, explanation: String) {
        self.provider = provider
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

        if let routePlan = planner.planRoute(
            input: SharedPlannerInput(
                constraints: SharedPlannerConstraints(
                    executionTarget: request.policy.execution,
                    networkOnline: online
                ),
                preferences: SharedPlannerPreferences(preferredProviderIds: []),
                providers: snapshots.map { $0.plannerInput },
                task: SharedPlannerTask(kind: request.task.kind.rawValue)
            )
        ) {
            return try selectFromSharedPlan(request: request, snapshots: snapshots, routePlan: routePlan)
        }

        return try selectLegacyRoute(
            request: request,
            snapshots: snapshots,
            networkOnline: online
        )
    }

    private func collectProviderSnapshots(hostServices: HostServices) async -> [ProviderSnapshot] {
        var snapshots = [ProviderSnapshot]()

        for provider in registry.list() {
            let descriptor = provider.describe()
            let capabilities = await provider.capabilities(host: hostServices)
            snapshots.append(
                ProviderSnapshot(
                    provider: provider,
                    descriptor: descriptor,
                    capabilities: capabilities
                )
            )
        }

        return snapshots.sorted {
            $0.descriptor.id < $1.descriptor.id
        }
    }

    private func selectFromSharedPlan(
        request: TaskRequest,
        snapshots: [ProviderSnapshot],
        routePlan: SharedPlannerRoutePlan
    ) throws -> RouteSelection {
        if let selectedProviderId = routePlan.selectedProviderId,
           let snapshot = snapshots.first(where: { $0.descriptor.id == selectedProviderId }) {
            return RouteSelection(provider: snapshot.provider, explanation: routePlan.explanation.summary)
        }

        let message = routePlan.explanation.summary
        switch routePlan.failureCode {
        case .offline:
            throw createOffline(message: message)
        case .unavailable:
            throw createUnavailable(message: message)
        case .capabilityMismatch:
            throw createCapabilityMismatch(message: message)
        default:
            switch request.policy.execution {
            case .onDevice:
                throw createCapabilityMismatch(message: message)
            case .cloud:
                throw createUnavailable(message: message)
            }
        }
    }

    private func selectLegacyRoute(
        request: TaskRequest,
        snapshots: [ProviderSnapshot],
        networkOnline: Bool
    ) throws -> RouteSelection {
        let taskKind = request.task.kind.rawValue
        let taskCandidates = snapshots.filter {
            $0.descriptor.tasks.contains(taskKind) && $0.descriptor.supports.run
        }

        switch request.policy.execution {
        case .onDevice:
            let localCandidates = taskCandidates.filter {
                $0.descriptor.type == ProviderDescriptor.ProviderType.local
            }

            if localCandidates.isEmpty {
                throw createCapabilityMismatch(
                    message: "Capability mismatch: no on-device provider found supporting task '\(taskKind)'."
                )
            }

            if let selected = localCandidates.first(where: { $0.capabilities.available }) {
                return RouteSelection(
                    provider: selected.provider,
                    explanation: "Selected on-device provider '\(selected.descriptor.id)' deterministically."
                )
            }

            throw createCapabilityMismatch(
                message: "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
            )

        case .cloud:
            if !networkOnline {
                throw createOffline(
                    message: "Offline: cloud execution selected, but no network connection is available."
                )
            }

            let cloudCandidates = taskCandidates.filter {
                $0.descriptor.type == ProviderDescriptor.ProviderType.cloud
            }

            if cloudCandidates.isEmpty {
                throw createUnavailable(
                    message: "Unavailable: no cloud provider found supporting task '\(taskKind)'."
                )
            }

            if let selected = cloudCandidates.first(where: { $0.capabilities.available }) {
                return RouteSelection(
                    provider: selected.provider,
                    explanation: "Selected cloud provider '\(selected.descriptor.id)' deterministically."
                )
            }

            throw createUnavailable(
                message: "Unavailable: cloud execution selected, but no cloud provider is currently available."
            )
        }
    }
}

private struct ProviderSnapshot: Sendable {
    let provider: any ProviderAdapter
    let descriptor: ProviderDescriptor
    let capabilities: ProviderDynamicCapabilities

    var plannerInput: SharedPlannerProviderInput {
        SharedPlannerProviderInput(
            capabilities: SharedPlannerCapabilities(
                available: capabilities.available,
                reason: nil
            ),
            descriptor: SharedPlannerProviderDescriptor(
                id: descriptor.id,
                supports: SharedPlannerProviderSupports(run: descriptor.supports.run),
                tasks: descriptor.tasks,
                type: DescriptorType(rawValue: descriptor.type.rawValue) ?? .local
            )
        )
    }
}
