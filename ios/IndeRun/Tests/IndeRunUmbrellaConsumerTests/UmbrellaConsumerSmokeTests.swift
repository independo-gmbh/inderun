import XCTest
import IndeRunSwift

// Consumer-compilation smoke test for the umbrella product. The Swift counterpart
// of android/inderun-consumer-smoke.
//
// The point is this target's dependency list in Package.swift: `IndeRunSwift` and
// nothing else, matching an app that depends on the `IndeRun` product alone. The
// SDK's own signatures take and return types from IndeRunContracts and
// IndeRunCore, so those must arrive through the `@_exported import` chain in
// Exports.swift. Deleting one of those attributes compiles fine everywhere else
// in this package -- IndeRunTests depends on all six modules directly, which is
// exactly what hid the problem until #189 -- and fails here with
// "cannot find type 'TaskRequest' in scope".
//
// Do not add dependencies or imports to this target. Reaching these types
// through one import is the assertion.
final class UmbrellaConsumerSmokeTests: XCTestCase {
    /// The root README's quick start, typed.
    private func request() -> TaskRequest {
        TaskRequest(
            prompt: "Translate 'Hello' to Spanish",
            constraints: TaskRequestConstraints(privacy: .localRequired)
        )
    }

    func testContractTypesAreReachableThroughTheUmbrellaProduct() {
        XCTAssertEqual(request().prompt, "Translate 'Hello' to Spanish")
        XCTAssertEqual(request().constraints?.privacy, .localRequired)
    }

    /// Names the engine's own return types. `TaskResult` and `StreamRun` are what
    /// `run`/`stream` hand back, so a consumer cannot use the SDK without them.
    func testEngineSignatureTypesAreReachable() {
        let engine: (any IndeRunApi)? = nil
        XCTAssertNil(engine)

        let run: (TaskRequest) async throws -> TaskResult = { _ in
            throw createInternal(message: "not executed", runId: "smoke")
        }
        let stream: (TaskRequest) async throws -> StreamRun = { _ in
            throw createInternal(message: "not executed", runId: "smoke")
        }
        XCTAssertNotNil(run)
        XCTAssertNotNil(stream)
    }
}
