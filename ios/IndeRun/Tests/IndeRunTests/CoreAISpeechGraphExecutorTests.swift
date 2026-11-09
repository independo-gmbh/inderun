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

    // The bound check runs before the graph lookup, so an unloaded executor tells a size inside the bound
    // (`graph not loaded`) from one past it (`input exceeds the Core AI bound`) without any model.
    private func assertRun(
        role: String, inputs: [String: SpeechTensor], message: String, kind: NeuralSpeechRuntimeErrorKind,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let executor = CoreAISpeechGraphExecutor(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await executor.run(role: role, inputs: inputs)
            XCTFail("expected a failure", file: file, line: line)
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, kind, file: file, line: line)
            XCTAssertEqual(error.message, message, file: file, line: line)
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    private func textInputs(_ n: Int) -> [String: SpeechTensor] {
        ["text_ids": SpeechTensor(shape: [1, n], data: .i64([Int64](repeating: 0, count: n)))]
    }

    private func floatInputs(_ name: String, _ n: Int) -> [String: SpeechTensor] {
        [name: SpeechTensor(shape: [1, n, 96], data: .f32([Float](repeating: 0, count: n * 96)))]
    }

    func testTextLongerThanTheBoundThrows() async throws {
        try await assertRun(
            role: "text", inputs: textInputs(258), message: "input exceeds the Core AI bound: text.text_ids 258 > 257", kind: .capability
        )
    }

    func testFramesAboveTheBoundThrow() async throws {
        try await assertRun(
            role: "dit_step", inputs: floatInputs("x", 1025), message: "input exceeds the Core AI bound: dit_step.x 1025 > 1024",
            kind: .capability
        )
        try await assertRun(
            role: "decoder", inputs: floatInputs("latents", 1037), message: "input exceeds the Core AI bound: decoder.latents 1037 > 1036",
            kind: .capability
        )
    }

    func testBoundsAllowTheMaximum() async throws {
        try await assertRun(role: "text", inputs: textInputs(257), message: "graph not loaded: text", kind: .internalFailure)
        try await assertRun(role: "dit_step", inputs: floatInputs("x", 1024), message: "graph not loaded: dit_step", kind: .internalFailure)
        try await assertRun(role: "decoder", inputs: floatInputs("latents", 1036), message: "graph not loaded: decoder", kind: .internalFailure)
    }

    // MARK: - Fixed shapes (the pure check, so no Core AI is needed)

    private func zeros(_ shape: [Int]) -> SpeechTensor {
        SpeechTensor(shape: shape, data: .f32([Float](repeating: 0, count: shape.reduce(1, *))))
    }

    private func assertRefused(
        role: String, _ inputs: [String: SpeechTensor], _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try checkCoreAIBounds(role: role, inputs: inputs), file: file, line: line) { error in
            let error = error as? NeuralSpeechRuntimeError
            XCTAssertEqual(error?.kind, .capability, file: file, line: line)
            XCTAssertEqual(error?.message, message, file: file, line: line)
        }
    }

    func testTheExportedShapesPass() throws {
        for role in ["text", "dit_step", "decoder"] {
            let inputs = try XCTUnwrap(CoreAIArticulinoSignature.warmUpInputs(role: role))
            XCTAssertNoThrow(try checkCoreAIBounds(role: role, inputs: inputs), role)
        }
    }

    func testAVoiceCacheOfAnotherPromptLengthIsRefused() {
        assertRefused(
            role: "dit_step", ["voice_cache": zeros([8, 2, 1, 6, 124, 64])],
            "input shape unsupported by the Core AI export: dit_step.voice_cache [8,2,1,6,124,64], expected [8,2,1,6,125,64]"
        )
    }

    func testAFixedDimensionOrRankOffTheExportIsRefused() {
        assertRefused(
            role: "dit_step", ["x": zeros([1, 2, 95])],
            "input shape unsupported by the Core AI export: dit_step.x [1,2,95], expected [1,*,96]"
        )
        assertRefused(
            role: "dit_step", ["voice_tokens": zeros([1, 31, 768])],
            "input shape unsupported by the Core AI export: dit_step.voice_tokens [1,31,768], expected [1,32,768]"
        )
        assertRefused(
            role: "decoder", ["latents": zeros([2, 2, 96])],
            "input shape unsupported by the Core AI export: decoder.latents [2,2,96], expected [1,*,96]"
        )
        assertRefused(
            role: "text", ["voice_vector": zeros([768])],
            "input shape unsupported by the Core AI export: text.voice_vector [768], expected [1,768]"
        )
    }

    func testAnEmptyVariableAxisIsRefusedButOneFrameIsAccepted() {
        assertRefused(
            role: "dit_step", ["x": zeros([1, 0, 96])],
            "input shape unsupported by the Core AI export: dit_step.x [1,0,96], expected [1,*,96]"
        )
        XCTAssertNoThrow(try checkCoreAIBounds(role: "dit_step", inputs: ["x": zeros([1, 1, 96]), "frame_cond": zeros([1, 1, 512])]))
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
