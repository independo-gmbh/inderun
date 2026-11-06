import Foundation
import XCTest
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech

/// Runs the German speech text frontend scenarios of `contracts/fixtures/speech/german-frontend.json`
/// through the shared Rust core's C binding, the same file the Rust tests and the other SDKs run.
final class GermanFrontendConformanceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let locale: String
            let input: String
            let expected: String
        }

        let cases: [Case]
    }

    /// Guards against a fixture that silently lost cases, or a runner that skipped them.
    private static let expectedCaseCount = 82

    func testEveryScenarioNormalizesAsTheFixtureExpects() throws {
        let url = repositoryRoot().appendingPathComponent("contracts/fixtures/speech/german-frontend.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))

        XCTAssertEqual(fixture.cases.count, Self.expectedCaseCount)
        for scenario in fixture.cases {
            XCTAssertEqual(SharedCoreSpeechText.normalize(scenario.input, locale: scenario.locale), scenario.expected, scenario.id)
        }
    }

    func testAnEmbeddedNulCharacterDoesNotCrashTheBinding() {
        // A Swift string may hold U+0000; the C string ends there, which the core sees as a shorter text.
        XCTAssertEqual(SharedCoreSpeechText.normalize("Hallo\u{0}Welt", locale: "de-DE"), "Hallo")
    }
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/GermanFrontendConformanceTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}
