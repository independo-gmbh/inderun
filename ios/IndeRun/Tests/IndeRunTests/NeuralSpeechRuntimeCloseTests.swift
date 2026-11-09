import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech
@testable import IndeRunOnnxProviders
@testable import IndeRunCoreAIProviders

/// `close()` of the composed neural speech runtimes. Mirrors `onnx neural speech runtime close` on
/// Web (`onnx-runtime.test.ts`); the executor-boundary cases run through the shared
/// `SpeechRuntimeLifecycle`, which both composed runtimes build their executors with.
final class NeuralSpeechRuntimeCloseTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Lifecycle (shared by ONNX and Core AI)

    func testCloseIsIdempotentAndConcurrentClosesCloseEachExecutorOnce() async throws {
        let lifecycle = SpeechRuntimeLifecycle()
        let executors = (0 ..< 3).map { _ in RecordingExecutor() }
        for executor in executors { _ = lifecycle.guarded { executor } }

        async let first: Void = lifecycle.close()
        async let second: Void = lifecycle.close()
        _ = await (first, second)
        await lifecycle.close()

        XCTAssertEqual(executors.map(\.closeCount), [1, 1, 1])
        XCTAssertTrue(lifecycle.isClosed)
    }

    func testCloseDuringSynthesisWaitsForTheGraphBoundary() async throws {
        let lifecycle = SpeechRuntimeLifecycle()
        let inner = RecordingExecutor(holdingRole: "dit_step")
        let executor = try XCTUnwrap(lifecycle.guarded { inner })

        let running = Task { try await executor.run(role: "dit_step", inputs: [:]) }
        await inner.waitUntilHeld()

        let closeSettled = Flag()
        let closing = Task {
            await lifecycle.close()
            closeSettled.set()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inner.closeCount, 0, "the executor closed under a running graph call")
        XCTAssertFalse(closeSettled.value)

        inner.release()
        _ = try await running.value
        await closing.value

        XCTAssertEqual(inner.closeCount, 1)
        // The next graph boundary of the same synthesis ends with runtime_closed, not silent success.
        do {
            _ = try await executor.run(role: "decoder", inputs: [:])
            XCTFail("expected runtime_closed")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, "runtime closed")
            XCTAssertEqual(error.code, "runtime_closed")
        }
    }

    func testNothingIsCreatedAfterClose() async {
        let lifecycle = SpeechRuntimeLifecycle()
        await lifecycle.close()
        let built = Flag()
        let executor = lifecycle.guarded { built.set(); return RecordingExecutor() }
        XCTAssertNil(executor)
        XCTAssertFalse(built.value)
    }

    // MARK: - ONNX

    func testOnnxCloseReleasesEveryCachedPipelineExecutorExactlyOnce() async throws {
        let created = ExecutorLog()
        let runtime = makeOnnxRuntime(created)
        _ = await runtime.availability(try makePackage(version: "1"))
        _ = await runtime.availability(try makePackage(version: "2"))
        _ = await runtime.availability(try makePackage(version: "2"))
        XCTAssertEqual(created.executors.count, 2)

        async let first: Void = runtime.close()
        async let second: Void = runtime.close()
        _ = await (first, second)
        await runtime.close()

        XCTAssertEqual(created.executors.map(\.closeCount), [1, 1])
    }

    func testOnnxCloseDropsTheCachedPipelines() async throws {
        let created = ExecutorLog()
        let runtime = makeOnnxRuntime(created)
        _ = await runtime.availability(try makePackage(version: "1"))
        _ = await runtime.availability(try makePackage(version: "2"))
        let cachedBefore = await runtime.cachedPipelineCount()
        XCTAssertEqual(cachedBefore, 2)

        await runtime.close()

        let cachedAfter = await runtime.cachedPipelineCount()
        XCTAssertEqual(cachedAfter, 0, "a closed runtime kept its pipelines alive")
    }

    func testOnnxAfterCloseEverythingReportsRuntimeClosedAndNothingIsCreated() async throws {
        let created = ExecutorLog()
        let runtime = makeOnnxRuntime(created)
        await runtime.close()
        let package = try makePackage(version: "1")
        let closed = NeuralSpeechAvailability(available: false, reason: "runtime closed")

        let availability = await runtime.availability(package)
        let prepared = await runtime.prepare(package)
        XCTAssertEqual(availability, closed)
        XCTAssertEqual(prepared, closed)
        XCTAssertEqual(runtime.normalizeText(package, text: "Es sind 3 Mai.", locale: "de-DE"), "Es sind 3 Mai.")
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected runtime_closed")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, "runtime closed")
            XCTAssertEqual(error.code, "runtime_closed")
        }
        XCTAssertTrue(created.executors.isEmpty)
    }

    // MARK: - Core AI

    func testCoreAICloseThenEverythingReportsRuntimeClosed() async throws {
        let runtime = CoreAINeuralSpeechRuntime()
        runtime.isAvailableOverride = true
        runtime.isSpecialized = { _ in true }
        runtime.specialize = { _ in }
        runtime.assetFunctionNames = { _ in nil }
        let package = try makePackage(version: "1", format: "coreai", assets: true)
        let before = await runtime.availability(package)
        XCTAssertTrue(before.available)

        async let first: Void = runtime.close()
        async let second: Void = runtime.close()
        _ = await (first, second)

        let closed = NeuralSpeechAvailability(available: false, reason: "runtime closed")
        let availability = await runtime.availability(package)
        let prepared = await runtime.prepare(package)
        XCTAssertEqual(availability, closed)
        XCTAssertEqual(prepared, closed)
        XCTAssertEqual(runtime.normalizeText(package, text: "3", locale: "de-DE"), "3")
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected runtime_closed")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.message, "runtime closed")
            XCTAssertEqual(error.code, "runtime_closed")
        }
    }

    // MARK: - Helpers

    private func makeOnnxRuntime(_ log: ExecutorLog) -> OnnxNeuralSpeechRuntime {
        let runtime = OnnxNeuralSpeechRuntime()
        runtime.makeExecutor = { _ in log.make() }
        return runtime
    }

    private func makePackage(version: String, format: String = "onnx", assets: Bool = false) throws -> ModelPackage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("voices"), withIntermediateDirectories: true)
        directories.append(directory)
        let ext = format == "coreai" ? "aimodel" : "onnx"
        for file in ["text.\(ext)", "dit_step.\(ext)", "decoder.\(ext)", "config.json", "voices/v.safetensors"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data())
        }
        let graphs = format == "coreai"
            ? #"{"text":"text.aimodel","dit_step":"dit_step.aimodel#dit_step","decoder":"decoder.aimodel"}"#
            : #"{"text":"text.onnx","dit_step":"dit_step.onnx","decoder":"decoder.onnx"}"#
        let json = """
        {"id":"close-fixture","version":"\(version)","format":"\(format)","tasks":["text_to_speech"],
         "source":{"sourceType":"filesystem","ref":"\(directory.path)"},
         "speech":{"pipeline":"articulino","sampleRate":24000,"channels":1,"graphs":\(graphs),
          "frontend":{"kind":"grapheme","assets":{"config":"config.json"}},
          "voices":[{"id":"v","name":"V","locales":["de-DE"],"file":"voices/v.safetensors"}]}}
        """
        return try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ExecutorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RecordingExecutor] = []
    var executors: [RecordingExecutor] { lock.withLock { all } }
    func make() -> RecordingExecutor {
        let executor = RecordingExecutor()
        lock.withLock { all.append(executor) }
        return executor
    }
}

/// Counts `close()`; `run` of `holdingRole` blocks until `release()`.
private final class RecordingExecutor: SpeechGraphExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let holdingRole: String?
    private var closes = 0
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var isHeld = false
    private var released = false

    init(holdingRole: String? = nil) {
        self.holdingRole = holdingRole
    }

    var closeCount: Int { lock.withLock { closes } }

    func load(graphs: [String: String]) async throws {}

    func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
        guard role == holdingRole else { return [:] }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
                isHeld = true
                let waiter = heldWaiter
                heldWaiter = nil
                if released { return (true, waiter) }
                held = continuation
                return (false, waiter)
            }
            resumeNow.1?.resume()
            if resumeNow.0 { continuation.resume() }
        }
        return [:]
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if isHeld { return true }
                heldWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}
