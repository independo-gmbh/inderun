import Foundation
import IndeRunContracts
import InderunRouteCoreFFI

protocol RoutePlanning: Sendable {
    func planRoute(input: SharedPlannerInput) throws -> SharedPlannerRoutePlan
}

/// Why the shared route planner could not produce a plan.
///
/// The Web equivalent (`WasmUnavailableReason`) additionally has load-time
/// reasons -- `import_failed`, `init_failed` -- because a browser fetches and
/// instantiates the core at runtime. Here it is linked into the binary, so a
/// missing planner is a link failure at build time and cannot be a runtime state.
enum RoutePlannerUnavailableReason: String, Sendable {
    /// The planner input could not be encoded as JSON.
    case inputEncodeFailed = "input_encode_failed"
    /// The core returned nothing at all, which its C contract does not allow.
    case planFailed = "plan_failed"
    /// The core returned JSON that does not decode as a `RoutePlan`.
    case invalidPlanShape = "invalid_plan_shape"
}

/// Thrown instead of returning nil: there is no second planner to degrade to, so
/// every failure has to name itself rather than be swallowed into a re-plan under
/// different semantics. `Router` turns this into an `Internal` routing error.
struct RoutePlannerUnavailable: Error, Sendable {
    let reason: RoutePlannerUnavailableReason
}

typealias SharedPlannerInput = RoutePlannerInput
typealias SharedPlannerTask = RoutePlannerInputTask
typealias SharedPlannerConstraints = RoutePlannerInputConstraints
typealias SharedPlannerPreferences = RoutePlannerInputPreferences
typealias SharedPlannerProviderInput = Provider
typealias SharedPlannerProviderDescriptor = Descriptor
typealias SharedPlannerProviderSupports = Supports
typealias SharedPlannerCapabilities = Capabilities
typealias SharedPlannerRoutePlan = RoutePlan
typealias SharedPlannerRejectedProvider = RejectedProvider
typealias SharedPlannerRejectedReason = Reason
typealias SharedPlannerExplanation = Explanation

/// Calls the shared Rust route planner (`rust/inderun-route-core`) through its C
/// interface. The library is linked from the committed XCFramework that
/// `Package.swift` declares as a binary target, not loaded at runtime -- see
/// `scripts/build-route-core-apple.mjs`.
///
/// This is the only planner on iOS. Swift deliberately does not restate the
/// ranking, constraint, or rejection rules: a second copy of them is what drifted
/// on Web (issue #164) and here (issue #171), silently changing which provider
/// runs depending on which implementation answered.
final class SharedCoreRoutePlanner: RoutePlanning, @unchecked Sendable {
    static let shared = SharedCoreRoutePlanner()

    func planRoute(input: SharedPlannerInput) throws -> SharedPlannerRoutePlan {
        guard let inputData = try? input.jsonData(),
              let inputJson = String(data: inputData, encoding: .utf8) else {
            throw RoutePlannerUnavailable(reason: .inputEncodeFailed)
        }

        let outputJson: String = try inputJson.withCString { value in
            guard let rawOutput = inderun_plan_route_json(value) else {
                throw RoutePlannerUnavailable(reason: .planFailed)
            }

            // The buffer was allocated by Rust and is ours to release.
            defer {
                inderun_free_string(rawOutput)
            }

            return String(cString: rawOutput)
        }

        // Malformed input and planner errors come back as a well-formed RoutePlan
        // carrying `failureCode: unavailable`, which Router maps to a routing
        // error like any other refusal. Failing to decode means the contract
        // itself is out of sync, which is not a routing outcome.
        guard let plan = try? SharedPlannerRoutePlan(outputJson) else {
            throw RoutePlannerUnavailable(reason: .invalidPlanShape)
        }

        return plan
    }
}
