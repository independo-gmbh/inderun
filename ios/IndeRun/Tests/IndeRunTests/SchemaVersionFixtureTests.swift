import Foundation
import IndeRunContracts
import XCTest

/// ADR 025 section 5: every run-scoped document decodes with exactly one schema version.
/// `contracts/fixtures/versioning/schema-versions.json` is shared with the Web and Kotlin
/// suites; here every variant goes through `Codable`, which is what a bridge decodes with.
final class SchemaVersionFixtureTests: XCTestCase {
    private typealias Decode = (Data) throws -> Void

    private let decoders: [String: Decode] = [
        "TaskRequest": { _ = try JSONDecoder().decode(TaskRequest.self, from: $0) },
        "TaskResult": { _ = try JSONDecoder().decode(TaskResult.self, from: $0) },
        "IndeRunError": { _ = try JSONDecoder().decode(IndeRunError.self, from: $0) },
        "StreamRunHandle": { _ = try JSONDecoder().decode(StreamRunHandle.self, from: $0) },
        "StreamTerminalOutcome": { _ = try JSONDecoder().decode(StreamTerminalOutcome.self, from: $0) },
        "StreamEvent": { _ = try JSONDecoder().decode(StreamEvent.self, from: $0) },
        "ExecutionProvenance": { _ = try JSONDecoder().decode(ExecutionProvenance.self, from: $0) }
    ]

    func testEveryDocumentAcceptsOnlyTheCurrentVersion() throws {
        let fixture = try loadFixture()
        let documents = try XCTUnwrap(fixture["documents"] as? [[String: Any]])
        let accepted = try XCTUnwrap(fixture["accepted"] as? [String])
        let rejected = try XCTUnwrap(fixture["rejected"] as? [String])
        XCTAssertEqual(Set(documents.compactMap { $0["document"] as? String }), Set(decoders.keys))

        for entry in documents {
            let name = try XCTUnwrap(entry["document"] as? String)
            let payload = try XCTUnwrap(entry["payload"] as? [String: Any])
            let decode = try XCTUnwrap(decoders[name], name)
            for version in accepted {
                XCTAssertNoThrow(try decode(data(payload, version: version)), "\(name) \(version)")
            }
            for version in rejected {
                XCTAssertThrowsError(try decode(data(payload, version: version)), "\(name) \(version)")
            }
            // A StreamEvent's terminal payload is optional in the generated type, so only the
            // envelope's version is required to decode; every other document requires its own.
            XCTAssertThrowsError(try decode(data(payload, version: nil)), "\(name) missing")
        }
    }

    func testTheGeneratedVersionHasOneValue() {
        XCTAssertEqual(SchemaVersion(rawValue: "1.1"), .the11)
        XCTAssertNil(SchemaVersion(rawValue: "1.0"))
    }

    /// The payload with its version, and a nested terminal payload's version, replaced or removed.
    private func data(_ payload: [String: Any], version: String?) throws -> Data {
        func replace(_ value: [String: Any]) -> [String: Any] {
            var next = value
            next["schemaVersion"] = version
            return next
        }
        var next = replace(payload)
        if let nested = next["payload"] as? [String: Any], nested["schemaVersion"] != nil {
            next["payload"] = replace(nested)
        }
        return try JSONSerialization.data(withJSONObject: next)
    }

    private func loadFixture() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/versioning/schema-versions.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
}
