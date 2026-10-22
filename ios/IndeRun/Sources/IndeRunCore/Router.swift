import Foundation
import IndeRunContracts

/// One provider in the planned chain, with the voice the plan bound it to (speech only).
public struct RouteCandidate: Sendable {
    public let provider: any ProviderAdapter
    /// The voice this provider must use, chosen by the planner within the request's
    /// privacy policy. `nil` when the task has no voice or the provider does not list
    /// its voices.
    public let voice: ProviderVoice?

    public init(provider: any ProviderAdapter, voice: ProviderVoice? = nil) {
        self.provider = provider
        self.voice = voice
    }
}

public struct RouteSelection: Sendable {
    public let provider: any ProviderAdapter
    public let fallbackProviders: [any ProviderAdapter]
    /// The whole chain in attempt order (`provider` first), each with its bound voice.
    public let candidates: [RouteCandidate]
    public let routePlan: RoutePlan
    public let explanation: String

    /// `candidates` defaults to the chain without bound voices, so a selection built
    /// before voices existed keeps its meaning.
    public init(
        provider: any ProviderAdapter,
        fallbackProviders: [any ProviderAdapter],
        candidates: [RouteCandidate]? = nil,
        routePlan: RoutePlan,
        explanation: String
    ) {
        self.provider = provider
        self.fallbackProviders = fallbackProviders
        self.candidates = candidates
            ?? ([provider] + fallbackProviders).map { RouteCandidate(provider: $0) }
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
    ///
    /// `modelProfile` is a planning input in the same way: the planner rejects
    /// targets outside it with `not_in_model_profile`. `nil` means `auto`.
    public func selectRoute(
        request: TaskRequest,
        hostServices: HostServices,
        interactionMode: InteractionMode = .run,
        modelProfile: ModelProfile? = nil
    ) async throws -> RouteSelection {
        let online = await hostServices.connectivity.isOnline()
        let snapshots = await collectProviderSnapshots(hostServices: hostServices)
        let planInput = buildSharedPlannerInput(
            request: request,
            online: online,
            snapshots: snapshots,
            interactionMode: interactionMode,
            modelProfile: modelProfile
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
        let planned: [(id: String, candidate: RouteCandidate)] = routePlan.candidates.compactMap { candidate in
            snapshots.first(where: { $0.descriptor.id == candidate.providerId }).map { snapshot in
                (snapshot.descriptor.id, RouteCandidate(provider: snapshot.provider, voice: candidate.voice))
            }
        }

        guard let selectedId = routePlan.selectedProviderId ?? planned.first?.id,
              let selected = snapshots.first(where: { $0.descriptor.id == selectedId }) else {
            throw createInternal(message: "Route plan selected a provider that is no longer registered.")
        }

        let primary = planned.first { $0.id == selectedId }?.candidate ?? RouteCandidate(provider: selected.provider)
        let fallbacks = planned.filter { $0.id != selectedId }.map(\.candidate)

        return RouteSelection(
            provider: primary.provider,
            fallbackProviders: fallbacks.map(\.provider),
            candidates: [primary] + fallbacks,
            routePlan: routePlan,
            explanation: routePlan.explanation.summary
        )
    }

    /// Routing failure throws before any `route_decided` telemetry is emitted, so the
    /// plan's diagnostics are attached to the exception -- that is the only channel
    /// through which a caller learns *why* each provider was rejected.
    private func routePlanFailure(_ routePlan: RoutePlan) -> Error {
        let message = routePlan.explanation.summary
        let details = routePlanFailureDetails(routePlan)
        switch routePlan.failureCode {
        case .some(.offline):
            return createOffline(message: message, details: details)
        case .some(.unavailable):
            return createUnavailable(message: message, details: details)
        case .some(.capabilityMismatch), .none:
            return createCapabilityMismatch(message: message, details: details)
        }
    }

    /// `JSONAny` encodes primitives and nested collections of them, not arbitrary
    /// `Codable` values, so the plan's typed diagnostics are flattened by hand into
    /// the same JSON shape the Web SDK attaches.
    private func routePlanFailureDetails(_ routePlan: RoutePlan) -> [String: JSONAny] {
        var details: [String: JSONAny] = [
            "rejectedProviders": JSONAny(routePlan.rejectedProviders.map { rejected in
                [
                    "providerId": rejected.providerId,
                    "reasons": rejected.reasons.map { reason in
                        ["code": reason.code.rawValue, "message": reason.message]
                    }
                ] as [String: Any]
            })
        ]
        if let failureCode = routePlan.failureCode {
            details["failureCode"] = JSONAny(failureCode.rawValue)
        }
        return details
    }
}

private func buildSharedPlannerInput(
    request: TaskRequest,
    online: Bool,
    snapshots: [ProviderSnapshot],
    interactionMode: InteractionMode,
    modelProfile: ModelProfile?
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
        modelProfile: modelProfile,
        preferences: SharedPlannerPreferences(
            optimizeFor: preferences?.optimizeFor
        ),
        providers: snapshots.map { snapshot in
            SharedPlannerProviderInput(
                capabilities: streamingAwareCapabilities(for: snapshot),
                descriptor: snapshot.descriptor
            )
        },
        task: plannerTask(for: request)
    )
}

/// Projects the request's task onto the requirements the planner can check, through the
/// kind's task profile. Mirrors `plannerTask` in the Web SDK's route planner, whose
/// fallback for a kind without a profile has no Swift counterpart: such a kind does not
/// decode into `TaskKind`.
private func plannerTask(for request: TaskRequest) -> SharedPlannerTask {
    TaskProfiles.profile(for: request.task.kind).plannerTask(request)
}

/// Folds the "declares streaming but does not implement it" check into the
/// dynamic capability the planner sees, so the mismatch is rejected during
/// planning with an explanation instead of surfacing as an unexplained failure
/// later. Mirrors `toSharedPlannerCapabilities` in the Web SDK's route planner.
private func streamingAwareCapabilities(for snapshot: ProviderSnapshot) -> ProviderDynamicCapabilities {
    let declaresStreaming = snapshot.capabilities.streamingAvailable
        ?? snapshot.descriptor.supports.streaming
    let implementsStream = snapshot.provider is any StreamingProviderAdapter
    let streamingAvailable = declaresStreaming && implementsStream
    let streamingUnavailableReason = snapshot.capabilities.streamingUnavailableReason
        ?? (declaresStreaming && !implementsStream
            ? "Provider '\(snapshot.descriptor.id)' declares streaming but does not implement stream()."
            : nil)

    // Copy and override rather than rebuild, so a field added to the schema reaches the
    // planner without touching this function.
    var capabilities = snapshot.capabilities
    capabilities.streamingAvailable = streamingAvailable
    capabilities.streamingUnavailableReason = streamingAvailable ? nil : streamingUnavailableReason
    return capabilities
}

private struct ProviderSnapshot: Sendable {
    let provider: any ProviderAdapter
    let descriptor: ProviderDescriptor
    let capabilities: ProviderDynamicCapabilities
}
