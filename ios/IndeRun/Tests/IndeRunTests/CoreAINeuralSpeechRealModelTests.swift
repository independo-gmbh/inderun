import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunCoreAIProviders

/// Runs a real Articulino `coreai` package through Apple Core AI. Set `INDERUN_COREAI_MODEL_DIR` to
/// the package directory (`model-package.json`, `config.json`, the `.aimodel` graphs, `voices/`);
/// skipped otherwise, and wherever Core AI is unavailable.
final class CoreAINeuralSpeechRealModelTests: XCTestCase {
    private let host = HostServices(connectivity: MockConnectivityService(), clock: MockClockService())

    private func loadPackage() throws -> ModelPackage {
        guard CoreAISupport.isAvailable else { throw XCTSkip(CoreAISupport.unavailableReason) }
        guard let dir = ProcessInfo.processInfo.environment["INDERUN_COREAI_MODEL_DIR"] else {
            throw XCTSkip("set INDERUN_COREAI_MODEL_DIR to a coreai Articulino package directory")
        }
        let manifest = URL(fileURLWithPath: dir).appendingPathComponent("model-package.json")
        return try JSONDecoder().decode(ModelPackage.self, from: Data(contentsOf: manifest))
    }

    func testArticulinoSpeaksAGermanSentence() async throws {
        let package = try loadPackage()
        let runtime = CoreAINeuralSpeechRuntime()
        let prepared = await runtime.prepare(package)
        XCTAssertTrue(prepared.available, prepared.reason ?? "")
        // Prepared in this process: reported cold without probing the specialization cache.
        let afterPrepare = await runtime.availability(package)
        XCTAssertEqual(afterPrepare, NeuralSpeechAvailability(available: true, readiness: .cold))
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
        print("apple core ai real model: \(seconds) s audio in \(Date().timeIntervalSince(started)) s")
    }

    func testTheProviderReportsReadinessBeforeAndAfterPrepare() async throws {
        let package = try loadPackage()
        let provider = makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions(modelPackage: package))
        let before = await provider.capabilities(host: host)
        XCTAssertTrue(before.available, before.reason ?? "")
        let readiness = before.taskCapabilities?.first?.readiness
        XCTAssertTrue(readiness == .notPrepared || readiness == .cold, String(describing: readiness))

        let context = ProviderPrepareContext(runId: "prep-1", hostServices: host, task: "text_to_speech")
        for try await _ in provider.prepare(context: context) {}

        let after = await provider.capabilities(host: host)
        XCTAssertTrue(after.available, after.reason ?? "")
        // A loaded provider reports no readiness hint, which the router reads as ready.
        let ready = after.taskCapabilities?.first?.readiness
        XCTAssertTrue(ready == nil || ready == .ready, String(describing: ready))
    }
}
