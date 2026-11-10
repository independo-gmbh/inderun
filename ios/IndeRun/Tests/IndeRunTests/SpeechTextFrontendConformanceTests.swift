import Foundation
import XCTest
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech

/// Runs the speech text frontend scenarios of `contracts/fixtures/speech/german-frontend.json` and
/// `english-frontend.json` through the shared Rust core's C binding, the same files the Rust tests
/// and the other SDKs run.
final class SpeechTextFrontendConformanceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let locale: String
            let input: String
            let expected: String
        }

        let cases: [Case]
    }

    /// Each fixture with its case count, which guards against a fixture that silently lost cases,
    /// or a runner that skipped them.
    private static let fixtures: [(name: String, expectedCaseCount: Int)] = [
        ("german-frontend.json", 83),
        ("english-frontend.json", 37)
    ]

    func testEveryScenarioNormalizesAsTheFixtureExpects() throws {
        for (name, expectedCaseCount) in Self.fixtures {
            let url = repositoryRoot().appendingPathComponent("contracts/fixtures/speech/\(name)")
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))

            XCTAssertEqual(fixture.cases.count, expectedCaseCount, name)
            XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count, "\(name): duplicate id")
            for scenario in fixture.cases {
                XCTAssertEqual(
                    SharedCoreSpeechText.normalize(scenario.input, locale: scenario.locale),
                    scenario.expected,
                    "\(name) \(scenario.id)"
                )
            }
        }
    }

    func testAnEmbeddedNulCharacterKeepsTheRestOfTheText() {
        // A Swift string may hold U+0000; the binding passes a length, so the text does not end there.
        XCTAssertEqual(SharedCoreSpeechText.normalize("Hallo\u{0}Welt", locale: "de-DE"), "Hallo\u{0}Welt")
        XCTAssertEqual(SharedCoreSpeechText.normalize("Rendez\u{0}vous à 3 h.", locale: "fr"), "Rendez\u{0}vous à 3 h.")
    }
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/SpeechTextFrontendConformanceTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}
