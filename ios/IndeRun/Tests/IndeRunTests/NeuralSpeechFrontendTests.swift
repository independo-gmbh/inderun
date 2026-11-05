import Foundation
import XCTest
import IndeRunNeuralSpeech

/// The shared text frontend vectors (`contracts/fixtures/speech/neural-frontend.json`): the
/// sentence rule and the grapheme tokenizer, identical on all three SDKs. Mirrors
/// `frontend.test.ts`.
final class NeuralSpeechFrontendTests: XCTestCase {
    private struct FrontendCase: Decodable {
        let id: String
        let text: String
        let sentences: [String]
        let tokens: [[Int]]
    }

    private struct Fixture: Decodable {
        let vocab: [String: Int]
        let cases: [FrontendCase]
    }

    private func loadFixture() throws -> Fixture {
        let url = repositoryRoot().appendingPathComponent("contracts/fixtures/speech/neural-frontend.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testHasUniqueNonEmptyCaseIds() throws {
        let ids = try loadFixture().cases.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate case id in the fixture")
    }

    func testSplitsAndTokenizesEveryCase() throws {
        let fixture = try loadFixture()
        let tokenizer = GraphemeTokenizer(vocab: fixture.vocab)
        for entry in fixture.cases {
            let sentences = SpeechTextFrontend.splitSentences(entry.text)
            XCTAssertEqual(sentences, entry.sentences, entry.id)
            XCTAssertEqual(sentences.map(tokenizer.encode), entry.tokens, entry.id)
        }
    }
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/NeuralSpeechFrontendTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
