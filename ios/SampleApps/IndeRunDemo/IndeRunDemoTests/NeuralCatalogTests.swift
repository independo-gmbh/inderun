import XCTest
import IndeRunContracts
@testable import IndeRunDemo

/// Runs the shared `catalog-to-package.json` fixture against the demo's own mapping and parses
/// the real catalog the app bundles.
final class NeuralCatalogTests: XCTestCase {
    private func resource(_ name: String, in bundle: Bundle) throws -> Data {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing resource \(name).json")
        return try Data(contentsOf: url)
    }

    func testEveryMappingFixtureCaseProducesTheExpectedPackage() throws {
        let fixture = try resource("catalog-to-package", in: Bundle(for: Self.self))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 2)

        for fixtureCase in cases {
            let id = try XCTUnwrap(fixtureCase["id"] as? String)
            let ref = try XCTUnwrap(fixtureCase["ref"] as? String)
            let entryJSON = try JSONSerialization.data(withJSONObject: ["entries": [try XCTUnwrap(fixtureCase["entry"])]])
            let entry = try XCTUnwrap(NeuralCatalogParser.parse(entryJSON).first, id)

            let produced = try catalogEntryToModelPackage(entry, ref: ref)

            // Every schema-defined field is compared. The contract's licence types keep `spdx` and
            // `url`; `restrictions` and `attribution` live only in the catalog (ruling), so the
            // expected side drops them before the comparison.
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(produced)) as? NSDictionary
            let expected = Self.strippingCatalogOnlyLicenseFields(try XCTUnwrap(fixtureCase["expected"])) as? NSDictionary
            XCTAssertEqual(actual, expected, "case \(id)")
        }
    }

    private static func strippingCatalogOnlyLicenseFields(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object {
                if key == "license", var license = child as? [String: Any] {
                    license.removeValue(forKey: "restrictions")
                    license.removeValue(forKey: "attribution")
                    result[key] = license
                } else {
                    result[key] = strippingCatalogOnlyLicenseFields(child)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(strippingCatalogOnlyLicenseFields) }
        return value
    }

    func testTheBundledCatalogParsesAndLeavesTheCoreAIEntryUnavailable() throws {
        let entries = try NeuralCatalogParser.parse(resource("neural-model-catalog", in: Bundle(for: DemoViewModel.self)))
        let onnx = try XCTUnwrap(entries.first { $0.id == "articulino-de-en-int8" })
        XCTAssertTrue(onnx.isInstallable)
        XCTAssertEqual(onnx.voices.count, 7)
        XCTAssertEqual(onnx.ref, "voices-lab/articulino-de-en-int8/1")
        XCTAssertEqual(onnx.totalBytes, onnx.allFiles.map(\.bytes).reduce(0, +))

        let coreAI = try XCTUnwrap(entries.first { $0.id == "articulino-de-en-coreai" })
        XCTAssertFalse(coreAI.isInstallable)
        XCTAssertNotNil(coreAI.reviewNotes)
    }

    func testTheLabProfilesPairEachNeuralProviderWithTheOSVoice() {
        XCTAssertEqual(
            voicesLabProfiles(installedEntryIds: ["articulino-de-en-int8"]),
            ["voices-lab:articulino-de-en-int8": ["local.onnx.speech.apple:articulino-de-en-int8", "apple_system_speech"]]
        )
    }
}
