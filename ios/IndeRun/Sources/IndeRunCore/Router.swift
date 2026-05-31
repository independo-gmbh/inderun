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
    
    public init(registry: ProviderRegistry) {
        self.registry = registry
    }
    
    public func selectRoute(
        request: TaskRequest,
        hostServices: HostServices
    ) async throws -> RouteSelection {
        let taskKind = request.task.kind.rawValue
        let executionPolicy = request.policy.execution
        
        // 1. Map, sort, and filter candidate providers stably by ID to ensure deterministic selection
        let allCandidates = registry.list()
        let sortedCandidates = allCandidates.sorted {
            $0.describe().id < $1.describe().id
        }
        
        let taskCandidates = sortedCandidates.filter {
            $0.describe().tasks.contains(taskKind) && $0.describe().supports.run
        }
        
        switch executionPolicy {
        case .onDevice:
            let localCandidates = taskCandidates.filter {
                $0.describe().type == ProviderDescriptor.ProviderType.local
            }
            
            if localCandidates.isEmpty {
                throw createCapabilityMismatch(
                    message: "Capability mismatch: no on-device provider found supporting task '\(taskKind)'."
                )
            }
            
            // Check dynamic capabilities of local candidates
            for candidate in localCandidates {
                let caps = await candidate.capabilities(host: hostServices)
                if caps.available {
                    return RouteSelection(
                        provider: candidate,
                        explanation: "Selected on-device provider '\(candidate.describe().id)' deterministically."
                    )
                }
            }
            
            throw createCapabilityMismatch(
                message: "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
            )
            
        case .cloud:
            // Check network status before filtering cloud providers
            let online = await hostServices.connectivity.isOnline()
            if !online {
                throw createOffline(
                    message: "Offline: cloud execution selected, but no network connection is available."
                )
            }
            
            let cloudCandidates = taskCandidates.filter {
                $0.describe().type == ProviderDescriptor.ProviderType.cloud
            }
            
            if cloudCandidates.isEmpty {
                throw createUnavailable(
                    message: "Unavailable: no cloud provider found supporting task '\(taskKind)'."
                )
            }
            
            // Check dynamic capabilities of cloud candidates
            for candidate in cloudCandidates {
                let caps = await candidate.capabilities(host: hostServices)
                if caps.available {
                    return RouteSelection(
                        provider: candidate,
                        explanation: "Selected cloud provider '\(candidate.describe().id)' deterministically."
                    )
                }
            }
            
            throw createUnavailable(
                message: "Unavailable: cloud execution selected, but no cloud provider is currently available."
            )
        }
    }
}
