import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift
@testable import IndeRunOnnxProviders

/// Runs a real Articulino package through ONNX Runtime. Set `INDERUN_NEURAL_SPEECH_MODEL_DIR` to a
/// directory written by `tools/neural-speech/prepare_articulino_package.py`; skipped otherwise.
final class OnnxNeuralSpeechRealModelTests: XCTestCase {
    private func loadPackage() throws -> ModelPackage {
        guard let dir = ProcessInfo.processInfo.environment["INDERUN_NEURAL_SPEECH_MODEL_DIR"] else {
            throw XCTSkip("set INDERUN_NEURAL_SPEECH_MODEL_DIR to a directory written by tools/neural-speech/prepare_articulino_package.py")
        }
        let manifest = URL(fileURLWithPath: dir).appendingPathComponent("model-package.json")
        return try JSONDecoder().decode(ModelPackage.self, from: Data(contentsOf: manifest))
    }

    func testArticulinoSpeaksAGermanSentence() async throws {
        let package = try loadPackage()
        let runtime = OnnxNeuralSpeechRuntime()
        let prepared = await runtime.prepare(package)
        XCTAssertTrue(prepared.available, prepared.reason ?? "")
        let started = Date()
        var samples: [Int16] = []
        let voiceId = try XCTUnwrap(package.speech?.voices.first?.id)
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Ich habe Hunger.", locale: "de-DE", voiceId: voiceId)
        for try await chunk in runtime.synthesize(input) { samples += chunk.samples }
        let seconds = Double(samples.count) / 24000
        XCTAssertGreaterThan(seconds, 1)
        XCTAssertLessThan(seconds, 6)
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
        XCTAssertGreaterThan(energy.squareRoot(), 300)
        print("apple real model: \(seconds) s audio in \(Date().timeIntervalSince(started)) s")
    }

    func testArticulinoThroughTheProviderCommitsAndReportsTiming() async throws {
        let package = try loadPackage()
        let provider = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: OnnxNeuralSpeechRuntime()))
        let registry = ProviderRegistry()
        try registry.register(provider)
        let engine = IndeRun(
            registry: registry,
            hostServices: HostServices(
                connectivity: MockConnectivityService(),
                clock: MockClockService(),
                audioOutput: FixtureAudioOutputService()
            ),
            modelProfiles: try ModelProfiles(["neural": [provider.id]])
        )
        let playback = try await engine.speak(SpeakOptions("Ich habe Hunger.", locale: "de-DE", model: "neural"))
        let spoken = try await playback.result()
        XCTAssertNotEqual(spoken.finishReason, .cancelled)
        XCTAssertNotNil(spoken.timing?.firstChunkMs)
        let attempt = spoken.provenance?.attempts.first { $0.providerId == provider.id }
        XCTAssertEqual(attempt?.committed, true)
    }
}
