import Foundation
import XCTest
import IndeRunContracts
#if canImport(CoreAI)
import CoreAI
#endif
@testable import IndeRunCoreAIProviders

final class CoreAISpeechGraphExecutorTests: XCTestCase {
    func testRunBeforeLoadIsInternal() async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let executor = CoreAISpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await executor.run(role: "text", inputs: [:])
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .internalFailure)
            XCTAssertEqual(error.message, "graph not loaded: text")
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testLoadReportsAMissingGraphFile() async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executor = CoreAISpeechGraphExecutor(directory: directory)
        for value in ["text.aimodel", "text.aimodel#encoder"] {
            do {
                try await executor.load(graphs: ["text": value])
                XCTFail("expected a failure")
            } catch let error as NeuralSpeechRuntimeError {
                XCTAssertEqual(error.kind, .unavailable)
                XCTAssertEqual(error.message, "graph failed to load: text: model files missing: text.aimodel")
            }
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testLoadRefusesAGraphFileNameOutsideThePackage() async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let executor = CoreAISpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        for (value, file) in [("../text.aimodel", "../text.aimodel"), ("/etc/text.aimodel", "/etc/text.aimodel"), ("../a.aimodel#text", "../a.aimodel")] {
            do {
                try await executor.load(graphs: ["text": value])
                XCTFail("expected \(value) to be refused")
            } catch let error as NeuralSpeechRuntimeError {
                XCTAssertEqual(error.kind, .unavailable)
                XCTAssertEqual(error.message, "graph failed to load: text: model file name invalid: \(file)")
            }
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testLoadRefusesAnInvalidReferenceBeforeTouchingAnyFile() async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let executor = CoreAISpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        do {
            try await executor.load(graphs: ["decoder": "missing.aimodel", "text": "a.aimodel#b#c"])
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .capability)
            XCTAssertEqual(error.message, "graph reference invalid: text: a.aimodel#b#c")
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    /// Loads and runs a real Core AI package. Set `INDERUN_COREAI_MODEL_DIR` to a directory written by
    /// `tools/neural-speech/prepare_coreai_package.py`; skipped otherwise.
    func testLoadsAndRunsTheTextGraph() async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        guard let dir = ProcessInfo.processInfo.environment["INDERUN_COREAI_MODEL_DIR"] else {
            throw XCTSkip("set INDERUN_COREAI_MODEL_DIR to a directory written by tools/neural-speech/prepare_coreai_package.py")
        }
        let directory = URL(fileURLWithPath: dir)
        let package = try JSONDecoder().decode(ModelPackage.self, from: Data(contentsOf: directory.appendingPathComponent("model-package.json")))
        let speech = try XCTUnwrap(package.speech)
        let executor = CoreAISpeechGraphExecutor(directory: directory)
        try await executor.load(graphs: speech.graphs)
        for (role, value) in speech.graphs {
            let reference = try CoreAIGraphReference(role: role, value: value)
            let model = try XCTUnwrap(try AIModelCache.default.model(for: directory.appendingPathComponent(reference.file), options: .default))
            XCTAssertTrue(model.functionNames.contains(reference.function), "\(reference.function) in \(model.functionNames)")
        }

        let configFile = try XCTUnwrap(speech.frontend?.assets?["config"])
        let config = try ArticulinoConfig.parse(Data(contentsOf: directory.appendingPathComponent(configFile)))
        let voiceFile = try XCTUnwrap(speech.voices.first?.file)
        let voice = try Safetensors.parse(Data(contentsOf: directory.appendingPathComponent(voiceFile)))
        let language = Int64(try XCTUnwrap(config.languages["de"] ?? config.languages.values.min()))
        let ids: [Int64] = [0, 9, 2, 13]
        let outputs = try await executor.run(role: "text", inputs: [
            "text_ids": SpeechTensor(shape: [1, ids.count], data: .i64(ids)),
            "language": SpeechTensor(shape: [1, ids.count], data: .i64(Array(repeating: language, count: ids.count))),
            "text_mask": SpeechTensor(shape: [1, ids.count], data: .i64([0, 1, 1, 1])),
            "voice_vector": try XCTUnwrap(voice.tensors["voice_vector"])
        ])
        let features = try XCTUnwrap(outputs["text_features"])
        XCTAssertEqual(features.shape.count, 3)
        XCTAssertEqual(Array(features.shape.prefix(2)), [1, ids.count])
        let durations = try XCTUnwrap(outputs["log_durations"])
        XCTAssertEqual(durations.shape.reduce(1, *), ids.count)
        await executor.close()
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }
}
