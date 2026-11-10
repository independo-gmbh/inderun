import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunOnnxProviders

final class OnnxSpeechGraphExecutorTests: XCTestCase {
    func testRunBeforeLoadIsInternal() async {
        let executor = OnnxSpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await executor.run(role: "text", inputs: [:])
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .internalFailure)
            XCTAssertEqual(error.message, "graph not loaded: text")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLoadReportsAMissingGraphFile() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executor = OnnxSpeechGraphExecutor(directory: directory)
        do {
            try await executor.load(graphs: ["text": "text.onnx"])
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, "graph failed to load: text: model files missing: text.onnx")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLoadRefusesAGraphFileNameOutsideThePackage() async {
        let executor = OnnxSpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        for name in ["../text.onnx", "/etc/text.onnx", ""] {
            do {
                try await executor.load(graphs: ["text": name])
                XCTFail("expected \(name) to be refused")
            } catch let error as NeuralSpeechRuntimeError {
                XCTAssertEqual(error.kind, .unavailable)
                XCTAssertEqual(error.message, "graph failed to load: text: model file name invalid: \(name)")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testComposedRuntimeRefusesAPackageThatNeedsMoreMemoryThanTheDeviceHas() async throws {
        let package = try makePackage(
            pipeline: "articulino", source: #"{"sourceType":"filesystem","ref":"/nonexistent"}"#, limits: #"{"memBytes":2000}"#
        )
        let small = OnnxNeuralSpeechRuntime(options: OnnxNeuralSpeechRuntimeOptions(deviceMemoryBytes: { 1000 }))
        let refusal = NeuralSpeechAvailability(available: false, reason: "insufficient memory: package needs 2000 bytes, device has 1000 bytes")
        let availability = await small.availability(package)
        XCTAssertEqual(availability, refusal)
        let prepared = await small.prepare(package)
        XCTAssertEqual(prepared, refusal)
        do {
            for try await _ in small.synthesize(NeuralSpeechSynthesisInput(modelPackage: package, text: "a", locale: "de", voiceId: "v")) {}
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, refusal.reason)
        }

        let large = OnnxNeuralSpeechRuntime(options: OnnxNeuralSpeechRuntimeOptions(deviceMemoryBytes: { 2000 }))
        let enough = await large.availability(package)
        XCTAssertFalse(enough.reason?.hasPrefix("insufficient memory") ?? false, enough.reason ?? "")
    }

    func testTensorValuesRoundTripThroughORTValue() throws {
        let f32 = SpeechTensor(shape: [1, 3], data: .f32([0.5, -1, 2.25]))
        let i64 = SpeechTensor(shape: [1, 3], data: .i64([1, -2, 9_000_000_000]))
        for tensor in [f32, i64] {
            XCTAssertEqual(try makeSpeechTensor(try makeORTValue(tensor)), tensor)
        }
    }

    func testComposedRuntimeRefusesAnUnknownPipeline() async throws {
        let package = try makePackage(pipeline: "other", source: #"{"sourceType":"filesystem","ref":"/nonexistent"}"#)
        let availability = await OnnxNeuralSpeechRuntime().availability(package)
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.reason, "unsupported pipeline 'other'")
    }

    func testComposedRuntimeReportsTheResolverMessage() async throws {
        let package = try makePackage(pipeline: "articulino", source: #"{"sourceType":"remote"}"#)
        let runtime = OnnxNeuralSpeechRuntime()
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertFalse(availability.available)
            XCTAssertTrue(availability.reason?.contains("model source unavailable") == true, availability.reason ?? "")
        }
    }

    private func makePackage(pipeline: String, source: String, limits: String = "null") throws -> ModelPackage {
        let json = """
        {"id":"t","version":"1","format":"onnx","tasks":["text_to_speech"],"source":\(source),"limits":\(limits),
         "speech":{"pipeline":"\(pipeline)","sampleRate":24000,"channels":1,"graphs":{"text":"text.onnx"},"voices":[]}}
        """
        return try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
    }
}
