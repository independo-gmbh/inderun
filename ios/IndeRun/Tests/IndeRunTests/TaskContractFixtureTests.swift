import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore

/// Runs the shared task-contract fixtures (`contracts/fixtures/task-contracts/`) through the
/// generated Swift types and the task-profile table (#245). For every file whose status is
/// `current`, each request must survive the `TaskRequest` Codable round trip, and the kind's
/// profile must project it onto exactly the recorded planner task -- the projection the Web
/// and Kotlin engines produce for the same request.
final class TaskContractFixtureTests: XCTestCase {
    func testCurrentRequestsRoundTripThroughTaskRequest() throws {
        let cases = try loadCurrentCases()
        XCTAssertFalse(cases.isEmpty)

        for (id, entry) in cases {
            let requestJson = try XCTUnwrap(entry["request"] as? [String: Any], id)
            let request = try JSONDecoder().decode(
                TaskRequest.self,
                from: JSONSerialization.data(withJSONObject: requestJson)
            )
            let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))

            XCTAssertEqual(reencoded as? NSDictionary, requestJson as NSDictionary, id)
        }
    }

    func testCurrentRequestsProjectOntoTheFixturePlannerTask() throws {
        let cases = try loadCurrentCases()
        XCTAssertFalse(cases.isEmpty)

        for (id, entry) in cases {
            let request = try JSONDecoder().decode(
                TaskRequest.self,
                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["request"], id))
            )
            let projected = TaskProfiles.profile(for: request.task.kind).plannerTask(request)
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projected))
            let expected = try XCTUnwrap(entry["planner"] as? [String: Any], id)

            XCTAssertEqual(actual as? NSDictionary, expected as NSDictionary, id)
        }
    }

    func testCurrentRequestsReportTheirDelivery() throws {
        for (id, entry) in try loadCurrentCases() {
            let request = try JSONDecoder().decode(
                TaskRequest.self,
                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["request"], id))
            )
            let planner = try XCTUnwrap(entry["planner"] as? [String: Any], id)
            let expected = (planner["delivery"] as? [String: Any])?["mode"] as? String ?? "inline"

            XCTAssertEqual(TaskProfiles.profile(for: request.task.kind).delivery(request).rawValue, expected, id)
        }
    }

    /// `(fixture task/case id, case)` for every case in a `current` fixture file.
    private func loadCurrentCases() throws -> [(String, [String: Any])] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/task-contracts")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var cases: [(String, [String: Any])] = []
        for file in files {
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            )
            guard root["status"] as? String == "current" else { continue }
            let task = try XCTUnwrap(root["task"] as? String)
            for entry in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
                cases.append(("\(task)/\(try XCTUnwrap(entry["id"] as? String))", entry))
            }
        }
        return cases
    }
}
