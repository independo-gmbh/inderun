import Foundation
import IndeRunCore
import IndeRunContracts

/// Accumulates what one execution did -- each attempt and how it ended -- and renders it
/// as the normalized `ExecutionProvenance` carried on results, terminal outcomes, and
/// errors. Mirrors `ProvenanceRecorder` in the Web SDK's engine.
///
/// Everything recorded is either observed by the engine (attempts, their outcomes) or
/// declared or reported by a provider (descriptor type and model, the model a response
/// names). Nothing is inferred: an unknown is left `nil` or reported as `.unknown`.
struct ProvenanceRecorder {
    private let modelProfile: String
    private var attempts: [ExecutionProvenanceAttempt] = []
    private var routeRejections: [ExecutionProvenanceRouteRejection] = []

    init(modelProfile: String?) {
        self.modelProfile = modelProfile ?? ModelProfiles.auto
    }

    /// Records the planner's rejections; codes only, never the provider-supplied messages.
    mutating func routed(_ routePlan: RoutePlan) {
        routeRejections = routePlan.rejectedProviders.map { rejected in
            ExecutionProvenanceRouteRejection(
                codes: rejected.reasons.map(\.code),
                providerId: rejected.providerId
            )
        }
    }

    /// Records the rejections a routing failure carried out on its exception's details,
    /// which `Router` flattens to plain JSON.
    mutating func routingFailed(_ details: [String: JSONAny]?) {
        guard let rejected = details?["rejectedProviders"]?.value as? [[String: Any]] else { return }
        routeRejections = rejected.compactMap { provider in
            guard let providerId = provider["providerId"] as? String else { return nil }
            let reasons = provider["reasons"] as? [[String: Any]] ?? []
            return ExecutionProvenanceRouteRejection(
                codes: reasons.compactMap { ($0["code"] as? String).flatMap(Code.init(rawValue:)) },
                providerId: providerId
            )
        }
    }

    /// Records how one provider attempt ended, and whether the run had committed to it
    /// (first content delivered, first possible audible effect, or an artifact handed over).
    mutating func attempted(
        _ providerId: String,
        _ outcome: AttemptOutcome,
        errorClass: IndeRunErrorClass? = nil,
        committed: Bool = false
    ) {
        attempts.append(
            ExecutionProvenanceAttempt(
                committed: committed ? true : nil, errorClass: errorClass, outcome: outcome, providerId: providerId
            )
        )
    }

    /// Renders the record. `attributedTo` is the provider the outcome belongs to -- the one
    /// that produced the result, the one a stream was committed to, or the one running at
    /// cancellation -- and is `nil` when no provider was reached or every attempt failed
    /// before a commit.
    func build(attributedTo descriptor: ProviderDescriptor? = nil, reportedModel: String? = nil) -> ExecutionProvenance {
        ExecutionProvenance(
            attemptCount: attempts.count,
            attempts: attempts,
            configuredModel: descriptor?.model,
            fallbackOccurred: attempts.count > 1,
            locality: descriptor.map(Self.locality(of:)) ?? .unknown,
            modelProfile: modelProfile,
            providerId: descriptor?.id,
            reportedModel: descriptor == nil ? nil : reportedModel,
            routeRejections: routeRejections,
            schemaVersion: .the10
        )
    }

    private static func locality(of descriptor: ProviderDescriptor) -> Locality {
        switch descriptor.type {
        case .local: return .onDevice
        case .edge: return .edge
        case .cloud: return .cloud
        }
    }
}
