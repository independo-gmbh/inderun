import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore

/// Runs the shared cross-SDK planner vectors (`contracts/fixtures/routing/planner-conformance.json`)
/// through the generated Swift contract types and the Rust core behind the C interface. Each
/// input is decoded into `RoutePlannerInput` — which is what proves the per-task capability and
/// requirement fields survive the Swift Codable round trip — and must plan to exactly the
/// recorded plan, messages included.
final class RoutePlannerConformanceTests: XCTestCase {
    func testMatchesTheSharedPlannerConformanceVectors() throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.isEmpty)

        for entry in cases {
            let id = try XCTUnwrap(entry["id"] as? String)
            let input = try JSONDecoder().decode(
                RoutePlannerInput.self,
                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["input"]))
            )
            let plan = try SharedCoreRoutePlanner.shared.planRoute(input: input)
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
            let expected = try XCTUnwrap(entry["expected"] as? [String: Any])

            XCTAssertEqual(actual as? NSDictionary, expected as NSDictionary, id)
        }
    }

    private func loadCases() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/routing/planner-conformance.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }
}
