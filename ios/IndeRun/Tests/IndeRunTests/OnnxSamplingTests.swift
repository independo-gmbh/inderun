import XCTest
import IndeRunContracts
@testable import IndeRunOnnxProviders

final class OnnxSamplingTests: XCTestCase {
    func testSelectTokenIsDeterministicArgmaxWithoutTemperature() {
        let sampling = SamplingConfig(generation: nil)
        let logits: [Float] = [0.1, 5.0, -2.0, 3.0]

        XCTAssertEqual(sampling.selectToken(from: logits), 1)
    }

    func testSelectTokenWithSeedIsReproducibleAcrossInstances() {
        let generation = Generation(maxOutputTokens: nil, seed: 42, stop: nil, temperature: 0.8, topP: nil)
        let logits: [Float] = [1.0, 2.0, 3.0, 0.5, 4.0]

        let first = SamplingConfig(generation: generation).selectToken(from: logits)
        let second = SamplingConfig(generation: generation).selectToken(from: logits)

        XCTAssertEqual(first, second)
    }

    func testSelectTokenWithTopPNarrowsToDominantCandidate() {
        // A single overwhelmingly likely logit plus low-probability noise: after softmax and a
        // tight topP, only the dominant index should remain in the candidate set regardless of
        // the (seeded, reproducible) random draw.
        let generation = Generation(maxOutputTokens: nil, seed: 7, stop: nil, temperature: 1.0, topP: 0.5)
        let logits: [Float] = [-10, -10, 20, -10, -10]

        let sampling = SamplingConfig(generation: generation)
        XCTAssertEqual(sampling.selectToken(from: logits), 2)
    }
}
