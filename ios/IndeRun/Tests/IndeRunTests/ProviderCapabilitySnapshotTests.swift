import Foundation
import XCTest
@testable import IndeRunContracts

/// Holds the generated `ProviderCapabilitySnapshot` to the shared vectors in
/// `contracts/fixtures/provider/capability-snapshots.json`: every valid snapshot decodes
/// and re-encodes to the same JSON object. That is what keeps an absent
/// `streamingAvailable` / `cancellationAvailable` absent — it means "inherit the static
/// declaration", and encoding it as `false` or `null` would change its meaning.
final class ProviderCapabilitySnapshotTests: XCTestCase {
    func testValidSnapshotsRoundTripWithoutGainingOrLosingKeys() throws {
        let fixtures = try loadValidSnapshots()
        XCTAssertFalse(fixtures.isEmpty)

        for (id, snapshot) in fixtures {
            let original = try JSONSerialization.data(withJSONObject: snapshot)
            let decoded = try JSONDecoder().decode(ProviderCapabilitySnapshot.self, from: original)
            let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))

            XCTAssertEqual(reencoded as? NSDictionary, snapshot as NSDictionary, id)
        }
    }

    func testAbsentTriStateFlagsDecodeAsNil() throws {
        let fixtures = try loadValidSnapshots()
        let inheriting = try XCTUnwrap(fixtures.first { $0.id == "cloud_streaming_inherits" })
        let decoded = try JSONDecoder().decode(
            ProviderCapabilitySnapshot.self,
            from: JSONSerialization.data(withJSONObject: inheriting.snapshot)
        )

        XCTAssertNil(decoded.capabilities.streamingAvailable)
        XCTAssertNil(decoded.capabilities.cancellationAvailable)
    }

    private func loadValidSnapshots() throws -> [(id: String, snapshot: [String: Any])] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/provider/capability-snapshots.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
        return try valid.map { entry in
            (
                id: try XCTUnwrap(entry["id"] as? String),
                snapshot: try XCTUnwrap(entry["snapshot"] as? [String: Any])
            )
        }
    }
}
