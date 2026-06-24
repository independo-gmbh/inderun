import Foundation
import IndeRunContracts
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

protocol RoutePlanning: Sendable {
    func planRoute(input: SharedPlannerInput) -> SharedPlannerRoutePlan?
}

typealias SharedPlannerInput = RoutePlannerInput
typealias SharedPlannerTask = RoutePlannerInputTask
typealias SharedPlannerConstraints = Constraints
typealias SharedPlannerPreferences = Preferences
typealias SharedPlannerProviderInput = Provider
typealias SharedPlannerProviderDescriptor = Descriptor
typealias SharedPlannerProviderSupports = Supports
typealias SharedPlannerCapabilities = Capabilities
typealias SharedPlannerRoutePlan = RoutePlan
typealias SharedPlannerRejectedProvider = RejectedProvider
typealias SharedPlannerRejectedReason = Reason
typealias SharedPlannerExplanation = Explanation

final class SharedCoreRoutePlanner: RoutePlanning, @unchecked Sendable {
    static let shared = SharedCoreRoutePlanner()

    private typealias PlanRouteJsonFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let planRouteJsonFn: PlanRouteJsonFn?
    private let freeStringFn: FreeStringFn?

    init() {
        let resolvedHandle = SharedCoreRoutePlanner.openLibrary()
        handle = resolvedHandle
        planRouteJsonFn = resolvedHandle.flatMap {
            guard let symbol = dlsym($0, "inderun_plan_route_json") else {
                return nil
            }
            return unsafeBitCast(symbol, to: PlanRouteJsonFn.self)
        }
        freeStringFn = resolvedHandle.flatMap {
            guard let symbol = dlsym($0, "inderun_free_string") else {
                return nil
            }
            return unsafeBitCast(symbol, to: FreeStringFn.self)
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func planRoute(input: SharedPlannerInput) -> SharedPlannerRoutePlan? {
        guard let planRouteJsonFn, let freeStringFn else {
            return nil
        }

        guard let inputData = try? input.jsonData(),
              let inputJson = String(data: inputData, encoding: .utf8) else {
            return nil
        }

        return inputJson.withCString { value in
            guard let rawOutput = planRouteJsonFn(value) else {
                return nil
            }

            defer {
                freeStringFn(rawOutput)
            }

            let outputJson = String(cString: rawOutput)
            return try? SharedPlannerRoutePlan(outputJson)
        }
    }

    private static func openLibrary() -> UnsafeMutableRawPointer? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["INDERUN_ROUTE_CORE_LIB_PATH"],
            "libinderun_route_core.dylib",
            "libinderun_route_core.so"
        ].compactMap { $0 }

        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_LAZY) {
                return handle
            }
        }

        return nil
    }
}
