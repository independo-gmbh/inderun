import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunNeuralSpeech

/// Runs `contracts/fixtures/speech/articulino-pipeline.json` against the Swift Articulino
/// pipeline with a scripted executor. One handler per case `kind`; the guard test fails when the
/// handler kinds and the fixture kinds differ. Mirrors `pipeline.conformance.test.ts`.
final class ArticulinoPipelineConformanceTests: XCTestCase {
    func testImplementsEveryCaseKindInTheSharedFixtureAndNoOthers() throws {
        let kinds = Set(try loadFixture().cases.map(\.kind))
        XCTAssertFalse(kinds.isEmpty)
        XCTAssertEqual(Set(handlers.keys), kinds)
    }

    func testLettersDe() async throws { try await run("letters_de") }
    func testLettersEnQuotes() async throws { try await run("letters_en_quotes") }
    func testLettersAccentsAndUnknown() async throws { try await run("letters_accents_and_unknown") }
    func testDurationsClampSpeed() async throws { try await run("durations_clamp_speed") }
    func testDurationsRateEqualised() async throws { try await run("durations_rate_equalised") }
    func testFrameConditionOverlap() async throws { try await run("frame_condition_overlap") }
    func testFlowSteps() async throws { try await run("flow_steps") }
    func testPostprocessShelfCutLimitPause() async throws { try await run("postprocess_shelf_cut_limit_pause") }
    func testLongSentenceSplit() async throws { try await run("long_sentence_split") }
    func testEndToEnd() async throws { try await run("end_to_end") }
    func testEmptyAfterLetters() async throws { try await run("empty_after_letters") }
    func testCancelBetweenGraphs() async throws { try await run("cancel_between_graphs") }

    func testEveryFixtureCaseHasATestInThisClass() throws {
        let ids = Set(try loadFixture().cases.map(\.id))
        let tested: Set<String> = [
            "letters_de", "letters_en_quotes", "letters_accents_and_unknown", "durations_clamp_speed",
            "durations_rate_equalised", "frame_condition_overlap", "flow_steps", "postprocess_shelf_cut_limit_pause",
            "long_sentence_split", "end_to_end", "empty_after_letters", "cancel_between_graphs"
        ]
        XCTAssertEqual(ids, tested)
    }

    private func run(_ id: String) async throws {
        let fixture = try loadFixture()
        let entry = try XCTUnwrap(fixture.cases.first { $0.id == id })
        let handler = try XCTUnwrap(handlers[entry.kind])
        try await handler(entry, fixture)
    }

    // MARK: Lifecycle

    func testAvailabilityRequiresVoiceFiles() async throws {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture)
        ))
        let ok = await runtime.availability(try fixturePackage())
        XCTAssertEqual(ok, NeuralSpeechAvailability(available: true))
        let missing = await runtime.availability(try fixturePackage(voiceFile: nil))
        XCTAssertEqual(missing, NeuralSpeechAvailability(available: false, reason: "voice file missing: v"))
    }

    func testRefusesADifferentPipelineAMissingConfigAndAMissingGraph() async throws {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture)
        ))
        let pipeline = await runtime.availability(try fixturePackage(pipeline: "x"))
        XCTAssertEqual(pipeline.reason, "unsupported pipeline 'x'")
        let config = await runtime.availability(try fixturePackage(frontendAssets: "{}"))
        XCTAssertEqual(config.reason, "pipeline config missing: speech.frontend.assets.config")
        let graph = await runtime.availability(try fixturePackage(graphs: #"{"text":"t.onnx","decoder":"d.onnx"}"#))
        XCTAssertEqual(graph.reason, "graph missing: dit_step")
    }

    func testPrepareRejectsABundleWithoutVoiceCache() async throws {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture, voice: try encodeVoice(fixture, drop: "voice_cache"))
        ))
        let result = await runtime.prepare(try fixturePackage())
        XCTAssertFalse(result.available)
        XCTAssertEqual(result.reason, "voice file malformed: v: missing tensor 'voice_cache'")
    }

    func testPrepareRejectsABundleWithTheWrongFormat() async throws {
        let fixture = try loadFixture()
        let bytes = try encodeSafetensors(voiceTensors(fixture), metadata: ["format": "other/1"])
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture, voice: bytes)
        ))
        let result = await runtime.prepare(try fixturePackage())
        XCTAssertEqual(result.reason, "voice file malformed: v: unexpected format 'other/1'")
    }

    func testRefusesAnUnsupportedLocaleAndAnUnknownVoice() async throws {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture)
        ))
        let package = try fixturePackage()
        await assertFails(runtime, package, locale: "fr-FR", voice: "v", kind: .capability, message: "locale unsupported: fr-FR")
        await assertFails(runtime, package, locale: "de-DE", voice: "nope", kind: .capability, message: "voice not found: nope")
    }

    func testAFailedPrepareSurfacesFromSynthesizeAsUnavailable() async throws {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(), files: try packageFiles(fixture, voice: try encodeVoice(fixture, drop: "voice_cache"))
        ))
        let package = try fixturePackage()
        _ = await runtime.prepare(package)
        await assertFails(
            runtime, package, locale: "de", voice: "v", kind: .unavailable,
            message: "voice file malformed: v: missing tensor 'voice_cache'"
        )
    }

    func testWrapsAnExecutorFailureThatIsNotARuntimeErrorAndPassesATypedOneThrough() async throws {
        let fixture = try loadFixture()
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let plain = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(failure: Boom()), files: try packageFiles(fixture)
        ))
        await assertFails(plain, try fixturePackage(), locale: "de", voice: "v", kind: .internalFailure, message: "pipeline failed: boom")
        let typed = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(failure: NeuralSpeechRuntimeError(kind: .unavailable, message: "gone")),
            files: try packageFiles(fixture)
        ))
        await assertFails(typed, try fixturePackage(), locale: "de", voice: "v", kind: .unavailable, message: "gone")
    }

    // MARK: Malformed model output

    private func malformedOutputFailure(_ script: Script) async throws -> NeuralSpeechRuntimeError {
        let fixture = try loadFixture()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: ScriptedExecutor(script: script), files: try packageFiles(fixture), noise: { [Float](repeating: 0, count: $0) }
        ))
        let input = NeuralSpeechSynthesisInput(modelPackage: try fixturePackage(), text: "ab", locale: "de", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
        } catch let error as NeuralSpeechRuntimeError {
            return error
        }
        throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "the stream ended without a failure")
    }

    private func textOutputs(logDurations: [Float], features: [Float]) -> [String: Tensor] {
        ["text_features": Tensor(shape: [1, 3, 2], data: features), "log_durations": Tensor(shape: [1, 3], data: logDurations)]
    }

    func testNonFiniteLogDurationsEndTheStreamWithAnInternalFailure() async throws {
        let script = Script(text: textOutputs(logDurations: [0, .nan, 0], features: [Float](repeating: 0, count: 6)), ditStep: nil, decoder: nil)
        let error = try await malformedOutputFailure(script)
        XCTAssertEqual(error.kind, .internalFailure)
        XCTAssertTrue(error.message.hasPrefix("pipeline failed: "), error.message)
    }

    func testShortTextFeaturesEndTheStreamWithAnInternalFailure() async throws {
        let script = Script(text: textOutputs(logDurations: [0, 1, 1], features: [0, 0]), ditStep: nil, decoder: nil)
        let error = try await malformedOutputFailure(script)
        XCTAssertEqual(error.kind, .internalFailure)
        XCTAssertEqual(error.message, "pipeline failed: text.text_features has 2 elements, expected 6")
    }

    func testShortVelocityEndsTheStreamWithAnInternalFailure() async throws {
        let script = Script(
            text: textOutputs(logDurations: [0, 1, 1], features: [Float](repeating: 0, count: 6)),
            ditStep: [["velocity": Tensor(shape: [1, 2, 2], data: [0])]], decoder: nil
        )
        let error = try await malformedOutputFailure(script)
        XCTAssertEqual(error.kind, .internalFailure)
        XCTAssertEqual(error.message, "pipeline failed: dit_step.velocity has 1 elements, expected 4")
    }

    // MARK: Directory package files

    func testDirectoryPackageFilesReadsAndRefusesUnsafeOrMissingNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("voices"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hi".utf8).write(to: directory.appendingPathComponent("voices/v.bin"))
        let files = DirectoryPackageFiles(directory: directory)

        let read = try await files.read("voices/v.bin")
        XCTAssertEqual(read, Data("hi".utf8))
        for (name, message) in [
            ("../x", "model file name invalid: ../x"), ("voices/../../x", "model file name invalid: voices/../../x"),
            ("/etc/passwd", "model file name invalid: /etc/passwd"), ("", "model file name invalid: "),
            ("nope.bin", "model files missing: nope.bin")
        ] {
            do {
                _ = try await files.read(name)
                XCTFail("expected \(name) to be refused")
            } catch let error as NeuralSpeechRuntimeError {
                XCTAssertEqual(error.kind, .capability)
                XCTAssertEqual(error.message, message)
            }
        }
    }

    private func assertFails(
        _ runtime: ArticulinoRuntime, _ package: ModelPackage, locale: String, voice: String,
        kind: NeuralSpeechRuntimeErrorKind, message: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "hallo", locale: locale, voiceId: voice)
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected a failure", file: file, line: line)
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, kind, file: file, line: line)
            XCTAssertEqual(error.message, message, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

// MARK: - Fixture

private struct Tensor: Decodable {
    let shape: [Int]
    let data: [Float]?
}

private struct Script: Decodable {
    let text: [String: Tensor]?
    let ditStep: [[String: Tensor]]?
    let decoder: [String: Tensor]?

    enum CodingKeys: String, CodingKey {
        case text, decoder
        case ditStep = "dit_step"
    }
}

private struct ExpectedCall: Decodable {
    let role: String
    let inputs: [String: Tensor]
}

private struct Input: Decodable {
    let logDurations: [Float]?
    let textMask: [Int64]?
    let speed: Float?
    let letterRate: Float?
    let textIds: [Int]?
    let features: Tensor?
    let durations: [Float]?
    let first: Int?
    let frames: Int?
    let noise: [Tensor]?
    let velocities: [Tensor]?
    let waveform: [Float]?
    let leadInFrames: Int?
    let pauseMs: Int?
}

private struct Expected: Decodable {
    let textIds: [Int]?
    let language: [Int]?
    let textMask: [Int]?
    let durations: [Float]?
    let frames: Int?
    let condition: Tensor?
    let latents: Tensor?
    let samples: [Int]?
    let pieces: [String]?
    let calls: [ExpectedCall]?
    let sampleRate: Int?
    let callsAtMost: Int?
}

private struct Case: Decodable {
    let id: String
    let kind: String
    let text: String?
    let language: String?
    let speed: Float?
    let pauseMs: Int?
    let cancelAfterCalls: Int?
    let executor: Script?
    let noise: [Tensor]?
    let input: Input?
    let expect: Expected
}

private struct Fixture: Decodable {
    let config: JSONValue
    let voice: [String: Tensor]
    let cases: [Case]
}

/// Keeps the fixture's `config` as-is so it can be written back out as `config.json`.
private enum JSONValue: Decodable {
    case any(Any)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: JSONValue].self) {
            self = .any(value.mapValues(\.raw))
        } else if let value = try? container.decode([JSONValue].self) {
            self = .any(value.map(\.raw))
        } else if let value = try? container.decode(String.self) {
            self = .any(value)
        } else if let value = try? container.decode(Double.self) {
            self = .any(value)
        } else {
            self = .any(try container.decode(Bool.self))
        }
    }

    var raw: Any {
        if case let .any(value) = self { return value }
        return NSNull()
    }
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/ArticulinoPipelineConformanceTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func loadFixture() throws -> Fixture {
    let url = repositoryRoot().appendingPathComponent("contracts/fixtures/speech/articulino-pipeline.json")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

private func fixtureConfig(_ fixture: Fixture) throws -> ArticulinoConfig {
    try ArticulinoConfig.parse(JSONSerialization.data(withJSONObject: fixture.config.raw))
}

// MARK: - Package, files and executor

private func fixturePackage(
    pipeline: String = "articulino",
    graphs: String = #"{"text":"text.onnx","dit_step":"dit_step.onnx","decoder":"decoder.onnx"}"#,
    frontendAssets: String = #"{"config":"config.json"}"#,
    voiceFile: String? = "voices/v.safetensors"
) throws -> ModelPackage {
    let file = voiceFile.map { #","file":"\#($0)""# } ?? ""
    let json = """
    {"id":"articulino-fixture","version":"1","format":"onnx","tasks":["text_to_speech"],"source":{"sourceType":"app_managed"},
     "speech":{"pipeline":"\(pipeline)","sampleRate":24000,"graphs":\(graphs),
      "frontend":{"kind":"grapheme","assets":\(frontendAssets)},
      "voices":[{"id":"v","name":"V","locales":["de-DE","en-US"]\(file)}]}}
    """
    return try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
}

private struct MemoryPackageFiles: SpeechPackageFiles {
    let files: [String: Data]

    func read(_ file: String) async throws -> Data {
        guard let data = files[file] else {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "model files missing: \(file)")
        }
        return data
    }
}

private func voiceTensors(_ fixture: Fixture) -> [(name: String, tensor: SpeechTensor)] {
    fixture.voice.keys.sorted().map { name in
        let tensor = fixture.voice[name]!
        return (name, SpeechTensor(shape: tensor.shape, data: .f32(tensor.data ?? [])))
    }
}

private func encodeVoice(_ fixture: Fixture, drop: String? = nil) throws -> Data {
    try encodeSafetensors(voiceTensors(fixture).filter { $0.name != drop }, metadata: ["format": "inderun.articulino.voice/1"])
}

private func packageFiles(_ fixture: Fixture, voice: Data? = nil) throws -> MemoryPackageFiles {
    MemoryPackageFiles(files: [
        "config.json": try JSONSerialization.data(withJSONObject: fixture.config.raw),
        "voices/v.safetensors": try voice ?? encodeVoice(fixture)
    ])
}

private struct RecordedCall {
    let role: String
    let inputs: [String: SpeechTensor]
}

/// Answers each role from the fixture's script (`dit_step` entries in order) and records every call.
private final class ScriptedExecutor: SpeechGraphExecutor, @unchecked Sendable {
    private let script: Script?
    private let failure: Error?
    private let afterCall: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var steps: [[String: Tensor]]
    private var recorded: [RecordedCall] = []

    init(script: Script? = nil, failure: Error? = nil, afterCall: (@Sendable (Int) -> Void)? = nil) {
        self.script = script
        self.failure = failure
        self.afterCall = afterCall
        self.steps = script?.ditStep ?? []
    }

    var calls: [RecordedCall] { lock.withLock { recorded } }

    func load(graphs: [String: String]) async throws {}

    func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
        let count = lock.withLock { () -> Int in
            recorded.append(RecordedCall(role: role, inputs: inputs))
            return recorded.count
        }
        afterCall?(count)
        if let failure { throw failure }
        let outputs: [String: Tensor]? = lock.withLock {
            switch role {
            case "text": return script?.text
            case "decoder": return script?.decoder
            default: return steps.isEmpty ? nil : steps.removeFirst()
            }
        }
        guard let outputs else { throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "no scripted output for \(role)") }
        return outputs.mapValues { SpeechTensor(shape: $0.shape, data: .f32($0.data ?? [])) }
    }

    func close() async {}
}

/// Hands out the fixture's noise tensors in order.
private final class NoiseTape: @unchecked Sendable {
    private let tensors: [Tensor]
    private let lock = NSLock()
    private var next = 0

    init(_ tensors: [Tensor]) { self.tensors = tensors }

    func draw() -> [Float] {
        lock.withLock {
            defer { next += 1 }
            return next < tensors.count ? tensors[next].data ?? [] : []
        }
    }
}

private func fixtureNoise(_ tensors: [Tensor]) -> NoiseSource {
    let tape = NoiseTape(tensors)
    return { _ in tape.draw() }
}

/// Cancels a task that is started after the cancellation was requested, too.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[PcmChunk], Error>?
    private var cancelled = false

    func set(_ task: Task<[PcmChunk], Error>) {
        let late = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if late { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<[PcmChunk], Error>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

// MARK: - Assertions

private let floatTolerance: Float = 1e-4

private func assertClose(
    _ actual: [Float], _ expected: [Float], tolerance: Float = floatTolerance, _ what: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, "\(what) length", file: file, line: line)
    for (a, e) in zip(actual, expected) {
        XCTAssertEqual(a, e, accuracy: tolerance, what, file: file, line: line)
    }
}

/// The tensor's elements as floats, whichever its element type.
private func floats(_ tensor: SpeechTensor?) -> [Float] {
    switch tensor?.data {
    case let .f32(values)?: return values
    case let .i64(values)?: return values.map(Float.init)
    case nil: return []
    }
}

private func assertCalls(_ actual: [RecordedCall], _ expected: [ExpectedCall], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.map(\.role), expected.map(\.role), file: file, line: line)
    for (call, want) in zip(actual, expected) {
        for (name, tensor) in want.inputs {
            let got = call.inputs[name]
            XCTAssertNotNil(got, "\(want.role).\(name)", file: file, line: line)
            XCTAssertEqual(got?.shape, tensor.shape, "\(want.role).\(name) shape", file: file, line: line)
            if let data = tensor.data {
                assertClose(floats(got), data, "\(want.role).\(name)", file: file, line: line)
            }
        }
    }
}

private func collect(_ stream: AsyncThrowingStream<PcmChunk, Error>) async throws -> [PcmChunk] {
    var chunks: [PcmChunk] = []
    for try await chunk in stream { chunks.append(chunk) }
    return chunks
}

private func synthesisInput(_ entry: Case) throws -> NeuralSpeechSynthesisInput {
    NeuralSpeechSynthesisInput(
        modelPackage: try fixturePackage(), text: try XCTUnwrap(entry.text), locale: try XCTUnwrap(entry.language), voiceId: "v"
    )
}

// MARK: - Handlers

private typealias Handler = (Case, Fixture) async throws -> Void

/// The voice's prompt frames P, read from `voice_cache`'s shape like the runtime does (never the config's `prefix_frames`).
private func promptFrames(_ fixture: Fixture) -> Int {
    fixture.voice["voice_cache"]?.shape[4] ?? -1
}

private let handlers: [String: Handler] = [
    "letters": { entry, fixture in
        let config = try fixtureConfig(fixture)
        let language = try XCTUnwrap(config.languages[try XCTUnwrap(entry.language)])
        let encoded = ArticulinoMath.encodeLetters(try XCTUnwrap(entry.text), language: language, config: config)
        XCTAssertEqual([0] + encoded.ids, entry.expect.textIds)
        XCTAssertEqual([encoded.languages.first ?? 0] + encoded.languages, entry.expect.language)
        XCTAssertEqual([0] + encoded.ids.map { _ in 1 }, entry.expect.textMask)
    },
    "durations": { entry, fixture in
        let config = try fixtureConfig(fixture)
        let input = try XCTUnwrap(entry.input)
        var d = ArticulinoMath.clampDurations(
            logDurations: try XCTUnwrap(input.logDurations), mask: try XCTUnwrap(input.textMask),
            speed: try XCTUnwrap(input.speed), maxUnits: config.maxDurationUnits
        )
        let letterRate = try XCTUnwrap(input.letterRate)
        if letterRate > 0 {
            ArticulinoMath.equalizeLetterRate(
                &d, ids: try XCTUnwrap(input.textIds), charset: config.charset, start: 1, target: letterRate * input.speed!
            )
        }
        d[0] = Float(config.durationUnitsPerFrame * promptFrames(fixture))
        assertClose(d, try XCTUnwrap(entry.expect.durations))
        XCTAssertEqual(ArticulinoMath.frameCount(d, units: config.durationUnitsPerFrame), entry.expect.frames)
    },
    "frameCondition": { entry, fixture in
        let config = try fixtureConfig(fixture)
        let input = try XCTUnwrap(entry.input)
        let features = try XCTUnwrap(input.features)
        let condition = ArticulinoMath.frameCondition(
            features: try XCTUnwrap(features.data), stride: features.shape[1], durations: try XCTUnwrap(input.durations),
            first: try XCTUnwrap(input.first), frames: try XCTUnwrap(input.frames), units: config.durationUnitsPerFrame
        )
        assertClose(condition, try XCTUnwrap(entry.expect.condition?.data))
    },
    "flowSteps": { entry, fixture in
        let config = try fixtureConfig(fixture)
        let input = try XCTUnwrap(entry.input)
        let noise = try XCTUnwrap(input.noise)
        let velocities = try XCTUnwrap(input.velocities)
        var x = noise[0].data ?? []
        var x1 = x
        for (k, t) in config.times.enumerated() {
            let hasNext = k + 1 < config.times.count
            let step = ArticulinoMath.flowStep(
                x: x, t: t, velocity: velocities[k].data ?? [],
                nextT: hasNext ? config.times[k + 1] : nil, nextNoise: hasNext ? noise[k + 1].data : nil
            )
            x1 = step.x1
            if let next = step.next { x = next }
        }
        assertClose(x1, try XCTUnwrap(entry.expect.latents?.data))
    },
    "postprocess": { entry, fixture in
        let config = try fixtureConfig(fixture)
        let input = try XCTUnwrap(entry.input)
        let shaped = ArticulinoMath.shapeWaveform(
            try XCTUnwrap(input.waveform), leadSamples: try XCTUnwrap(input.leadInFrames) * config.samplesPerFrame, config: config
        )
        let padded = ArticulinoMath.padSilence(shaped, pauseMs: try XCTUnwrap(input.pauseMs), sampleRate: config.sampleRate)
        let actual = ArticulinoMath.toInt16(padded)
        let expected = try XCTUnwrap(entry.expect.samples)
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) { XCTAssertLessThanOrEqual(abs(Int(a) - e), 1) }
    },
    "split": { entry, _ in
        XCTAssertEqual(ArticulinoMath.splitLongSentence(try XCTUnwrap(entry.text)), entry.expect.pieces)
    },
    "endToEnd": { entry, fixture in
        let executor = ScriptedExecutor(script: entry.executor)
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: executor, files: try packageFiles(fixture), noise: fixtureNoise(entry.noise ?? []),
            speed: entry.speed ?? 1, pauseMs: try XCTUnwrap(entry.pauseMs)
        ))
        let chunks = try await collect(runtime.synthesize(try synthesisInput(entry)))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.isLast, true)
        XCTAssertEqual(chunks.first?.sampleRate, entry.expect.sampleRate)
        let expected = try XCTUnwrap(entry.expect.samples)
        let actual = chunks.first?.samples ?? []
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) { XCTAssertLessThanOrEqual(abs(Int(a) - e), 1) }
        assertCalls(executor.calls, try XCTUnwrap(entry.expect.calls))
    },
    "cancel": { entry, fixture in
        let box = TaskBox()
        let limit = try XCTUnwrap(entry.cancelAfterCalls)
        let executor = ScriptedExecutor(script: entry.executor) { count in
            if count >= limit { box.cancel() }
        }
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: executor, files: try packageFiles(fixture), noise: fixtureNoise(entry.noise ?? []),
            pauseMs: try XCTUnwrap(entry.pauseMs)
        ))
        let stream = runtime.synthesize(try synthesisInput(entry))
        let task = Task { try await collect(stream) }
        box.set(task)
        let chunks = try await task.value
        XCTAssertEqual(chunks.count, 0)
        XCTAssertLessThanOrEqual(executor.calls.count, try XCTUnwrap(entry.expect.callsAtMost))
    }
]

// MARK: - Validation, long sentences and prepare (mirrors the web suite)

/// Answers every graph call with outputs shaped by its inputs: `text` gives two feature channels and
/// a duration of 6 units per letter, `dit_step` a velocity pulling `x` towards 0.5, `decoder` a sine
/// of `samplesPerFrame` samples per latent frame. The first `loadFailures` loads fail.
private final class ShapeFollowingExecutor: SpeechGraphExecutor, @unchecked Sendable {
    typealias Override = @Sendable ([String: SpeechTensor]) -> [String: SpeechTensor]

    private let samplesPerFrame: Int
    private let text: Override?
    private let ditStep: Override?
    private let loadFailures: Int
    private let lock = NSLock()
    private var recorded: [String] = []
    private var loadCount = 0

    init(samplesPerFrame: Int = 4, text: Override? = nil, ditStep: Override? = nil, loadFailures: Int = 0) {
        self.samplesPerFrame = samplesPerFrame
        self.text = text
        self.ditStep = ditStep
        self.loadFailures = loadFailures
    }

    var roles: [String] { lock.withLock { recorded } }
    var loads: Int { lock.withLock { loadCount } }

    func load(graphs: [String: String]) async throws {
        let attempt = lock.withLock { () -> Int in
            loadCount += 1
            return loadCount
        }
        if attempt <= loadFailures { throw NeuralSpeechRuntimeError(kind: .unavailable, message: "not yet") }
    }

    func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
        lock.withLock { recorded.append(role) }
        switch role {
        case "text":
            let n = inputs["text_ids"]?.shape[1] ?? 0
            let outputs = [
                "text_features": SpeechTensor(shape: [1, n, 2], data: .f32((0 ..< n * 2).map { Float(($0 % 7) - 3) / 10 })),
                "log_durations": SpeechTensor(shape: [1, n], data: .f32([Float](repeating: log(6), count: n)))
            ]
            return text?(outputs) ?? outputs
        case "dit_step":
            let x = try XCTUnwrap(inputs["x"])
            guard case let .f32(values) = x.data else { throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "x not f32") }
            let outputs = ["velocity": SpeechTensor(shape: x.shape, data: .f32(values.map { 0.5 - $0 }))]
            return ditStep?(outputs) ?? outputs
        default:
            let count = (inputs["latents"]?.shape[1] ?? 0) * samplesPerFrame
            if count > 10_000_000 {
                throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "scripted decoder asked for \(count) samples")
            }
            return ["waveform": SpeechTensor(shape: [1, count], data: .f32((0 ..< count).map { Float(sin(Double($0) / 3) * 0.3) }))]
        }
    }

    func close() async {}
}

private func patchedFiles(_ fixture: Fixture, _ patch: [String: Any] = [:], voice: Data? = nil) throws -> MemoryPackageFiles {
    var config = try XCTUnwrap(fixture.config.raw as? [String: Any])
    for (key, value) in patch { config[key] = value }
    return MemoryPackageFiles(files: [
        "config.json": try JSONSerialization.data(withJSONObject: config),
        "voices/v.safetensors": try voice ?? encodeVoice(fixture)
    ])
}

private func voiceWithLetterRate(_ fixture: Fixture, _ rate: Float) throws -> Data {
    let tensors = voiceTensors(fixture).map { entry in
        entry.name == "letter_rate" ? (entry.name, SpeechTensor(shape: [1], data: .f32([rate]))) : entry
    }
    return try encodeSafetensors(tensors, metadata: ["format": "inderun.articulino.voice/1"])
}

private let constantNoise: NoiseSource = { [Float](repeating: 0.1, count: $0) }

private func sentence(_ text: String) throws -> NeuralSpeechSynthesisInput {
    NeuralSpeechSynthesisInput(modelPackage: try fixturePackage(), text: text, locale: "de-DE", voiceId: "v")
}

private func failure(of stream: AsyncThrowingStream<PcmChunk, Error>) async -> NeuralSpeechRuntimeError? {
    do {
        for try await _ in stream {}
    } catch {
        return error as? NeuralSpeechRuntimeError
    }
    return nil
}

final class ArticulinoRuntimeValidationTests: XCTestCase {
    func testReadsPFromTheVoiceNotFromTheConfigPrefixFrames() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(promptFrames(fixture), 2)
        XCTAssertNotEqual(try fixtureConfig(fixture).prefixFrames, promptFrames(fixture))
    }

    func testRefusesAConfigValueOutOfRangeAtPrepare() async throws {
        let fixture = try loadFixture()
        let post = try XCTUnwrap((fixture.config.raw as? [String: Any])?["postprocess"] as? [String: Any])
        let cases: [([String: Any], String)] = [
            (["sample_rate": 1e20], "sample_rate must be an integer from 8000 to 192000"),
            (["latent_dim": 0], "latent_dim must be an integer from 1 to 4096"),
            (["samples_per_frame": 2.5], "samples_per_frame must be an integer from 1 to 65536"),
            (["duration_units_per_frame": 0], "duration_units_per_frame must be an integer from 1 to 1000"),
            (["prefix_frames": -1], "prefix_frames must be an integer from 0 to 100000"),
            (["decoder_lead_in_frames": -1], "decoder_lead_in_frames must be an integer from 0 to 100000"),
            (["max_duration_units": 0], "max_duration_units must be greater than 0 and at most 100000"),
            (["times": [0, 1]], "times[1] must be in [0, 1)"),
            (["languages": ["de": 0.5]], "languages.de must be an integer from 0 to 65535"),
            (["postprocess": post.merging(["peak": 1.5]) { $1 }], "postprocess.peak must be in (0, 1]"),
            (["postprocess": post.merging(["shelf_slope": 0]) { $1 }], "postprocess.shelf_slope must be greater than 0")
        ]
        for (patch, why) in cases {
            let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: ShapeFollowingExecutor(), files: try patchedFiles(fixture, patch)
            ))
            let result = await runtime.prepare(try fixturePackage())
            XCTAssertEqual(result.reason, "pipeline config malformed: \(why)")
        }
    }

    func testAcceptsALetterRateOfZeroAndRefusesOneOutside1To100() async throws {
        let fixture = try loadFixture()
        for (rate, expected) in [
            (Float(0), NeuralSpeechAvailability(available: true)), (100, NeuralSpeechAvailability(available: true)),
            (1e-6, nil), (0.5, nil), (101, nil), (-1, nil), (.nan, nil), (.infinity, nil)
        ] {
            let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: ShapeFollowingExecutor(), files: try patchedFiles(fixture, voice: try voiceWithLetterRate(fixture, rate))
            ))
            let result = await runtime.prepare(try fixturePackage())
            XCTAssertEqual(
                result, expected ?? NeuralSpeechAvailability(available: false, reason: "voice file malformed: v: letter_rate out of range"),
                "\(rate)"
            )
        }
    }

    func testBoundsTheFrameCountBeforeAllocating() async throws {
        let fixture = try loadFixture()
        let executor = ShapeFollowingExecutor(samplesPerFrame: 65536, text: { outputs in
            var outputs = outputs
            let n = outputs["log_durations"]?.shape[1] ?? 0
            outputs["log_durations"] = SpeechTensor(shape: [1, n], data: .f32([Float](repeating: log(1e5), count: n)))
            return outputs
        })
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
            executor: executor,
            files: try patchedFiles(fixture, ["samples_per_frame": 65536, "duration_units_per_frame": 1, "max_duration_units": 100_000]),
            noise: constantNoise
        ))
        let error = await failure(of: runtime.synthesize(try sentence("a.")))
        XCTAssertEqual(error?.kind, .internalFailure)
        let message = error?.message ?? ""
        XCTAssertNotNil(
            message.range(of: #"^pipeline failed: text\.log_durations yields \d+ frames, more than \d+$"#, options: .regularExpression),
            message
        )
    }

    func testALongSentenceSynthesizesEachPieceAndReturnsOneChunkWithOnePause() async throws {
        let fixture = try loadFixture()
        let config = try fixtureConfig(fixture)
        let split = try XCTUnwrap(fixture.cases.first { $0.id == "long_sentence_split" })
        let pieces = try XCTUnwrap(split.expect.pieces)
        XCTAssertEqual(pieces.count, 2)
        let pauseMs = 1
        let pause = Int((Double(pauseMs) / 1000 * Double(config.sampleRate)).rounded())

        func speak(_ text: String, _ executor: ShapeFollowingExecutor) async throws -> [PcmChunk] {
            let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: executor, files: try patchedFiles(fixture), noise: constantNoise, pauseMs: pauseMs
            ))
            return try await collect(runtime.synthesize(try sentence(text)))
        }

        let executor = ShapeFollowingExecutor()
        let chunks = try await speak(try XCTUnwrap(split.text), executor)
        XCTAssertEqual(executor.roles.filter { $0 == "text" }.count, 2)
        XCTAssertEqual(executor.roles.filter { $0 == "dit_step" }.count, 2 * config.times.count)
        XCTAssertEqual(executor.roles.filter { $0 == "decoder" }.count, 2)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.isLast, true)

        var expected: [Int16] = []
        for piece in pieces {
            let chunk = try await speak(piece, ShapeFollowingExecutor()).first
            let alone = try XCTUnwrap(chunk?.samples)
            XCTAssertGreaterThan(alone.count, pause)
            expected += alone.dropLast(pause)
        }
        expected += [Int16](repeating: 0, count: pause)
        XCTAssertEqual(chunks.first?.samples, expected)
    }

    func testPrepareReturnsTheRememberedOutcomeWithoutLoadingAgain() async throws {
        let fixture = try loadFixture()
        let executor = ShapeFollowingExecutor()
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(executor: executor, files: try patchedFiles(fixture)))
        let package = try fixturePackage()
        for _ in 0 ..< 2 {
            let result = await runtime.prepare(package)
            XCTAssertEqual(result, NeuralSpeechAvailability(available: true))
        }
        XCTAssertEqual(executor.loads, 1)
        var next = package
        next.version = "2"
        let upgraded = await runtime.prepare(next)
        XCTAssertEqual(upgraded, NeuralSpeechAvailability(available: true))
        XCTAssertEqual(executor.loads, 2)
    }

    func testPrepareLoadsAgainAfterAFailure() async throws {
        let fixture = try loadFixture()
        let executor = ShapeFollowingExecutor(loadFailures: 1)
        let runtime = ArticulinoRuntime(options: ArticulinoRuntimeOptions(executor: executor, files: try patchedFiles(fixture)))
        let package = try fixturePackage()
        let first = await runtime.prepare(package)
        XCTAssertEqual(first, NeuralSpeechAvailability(available: false, reason: "not yet"))
        for _ in 0 ..< 2 {
            let result = await runtime.prepare(package)
            XCTAssertEqual(result, NeuralSpeechAvailability(available: true))
        }
        XCTAssertEqual(executor.loads, 2)
    }
}
