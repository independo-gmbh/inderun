import Foundation
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech
@testable import IndeRunSwift
import XCTest

/// `IndeRun.close()`. Mirrors `engine-close.test.ts` on Web; the registry is app-built, so
/// close closes no providers and there is no owned-resources case.

/// A text provider whose `run` waits for `release()`.
private final class GatedRunProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { continuations = [] }
            return continuations
        }
        for continuation in waiting { continuation.resume() }
    }

    var hasEntered: Bool { lock.withLock { entered } }

    func describe() -> ProviderDescriptor {
        MockStreamProvider(id: "gated").describe()
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        lock.withLock { entered = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return TaskResult(
            runId: context.runId,
            output: TaskOutput(text: "ok"),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: "gated", totalMs: 0)
        )
    }
}

/// A preparable provider whose preparation never finishes on its own.
private final class HangingPrepareProvider: PreparableProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var cancelled = false

    var hasEntered: Bool { lock.withLock { entered } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: "hang",
            type: .local,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true, streaming: false, realtime: false, tools: false,
                reasoningEvents: false, structuredOutput: false, multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_text"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_text",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(prepare: true, run: true, stream: false),
                    cancel: .soft,
                    outputs: [ProviderTaskOutput(delivery: .inline)]
                )
            ]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [ProviderTaskAvailability(kind: "text_to_text", readiness: .cold)]
        )
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        TaskResult(
            runId: context.runId,
            output: TaskOutput(text: "ok"),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: "hang", totalMs: 0)
        )
    }

    func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                self.lock.withLock { self.entered = true }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self.lock.withLock { self.cancelled = Task.isCancelled }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class EngineCloseTests: XCTestCase {
    private let textRequest = TaskRequest(prompt: "Hello")

    private func host(audio: AudioOutputService? = nil) -> HostServices {
        HostServices(connectivity: MockConnectivityService(), clock: MockClockService(), audioOutput: audio)
    }

    private func engine(_ providers: [any ProviderAdapter]) throws -> IndeRun {
        let registry = ProviderRegistry()
        for provider in providers { try registry.register(provider) }
        return IndeRun(registry: registry, hostServices: host())
    }

    private func drain(_ run: StreamRun) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in run.events { events.append(event) }
        return events
    }

    private func assertSingleCancelledTerminal(
        _ events: [StreamEvent], file: StaticString = #filePath, line: UInt = #line
    ) {
        let terminals = events.filter { $0.type == "terminal" }
        XCTAssertEqual(terminals.count, 1, file: file, line: line)
        XCTAssertEqual(events.last?.type, "terminal", "nothing follows the terminal", file: file, line: line)
        XCTAssertEqual(terminals.first?.payload?.outcome, .cancelled, file: file, line: line)
    }

    private func assertEngineClosed<T>(
        _ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected engine_closed", file: file, line: line)
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable, file: file, line: line)
            XCTAssertEqual(error.details?["code"]?.value as? String, "engine_closed", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testCloseCancelsAnInFlightStreamWithExactlyOneCancelledTerminalAndNothingAfter() async throws {
        let provider = MockStreamProvider(id: "p1", script: [.init(.delta(text: "a")), .waitForCancellation])
        let engine = try engine([provider])
        let run = try await engine.stream(request: textRequest)
        let collected = Task { try await drain(run) }
        await provider.waitUntilEntered()

        await engine.close()
        let events = try await collected.value

        assertSingleCancelledTerminal(events)
    }

    func testCloseCancelsAnInFlightPrepare() async throws {
        let provider = HangingPrepareProvider()
        let engine = try engine([provider])
        let run = try await engine.prepare(request: PrepareRequest(allowDownload: nil, locale: nil, localeMatch: nil, privacy: nil, requestId: nil, tasks: nil, voice: nil))
        let collected = Task { try await drain(run) }
        for _ in 0 ..< 500 where !provider.hasEntered { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(provider.hasEntered)

        await engine.close()
        let events = try await collected.value

        assertSingleCancelledTerminal(events)
    }

    func testCloseWaitsForAnInFlightRunToSettleAndDoesNotCancelIt() async throws {
        let provider = GatedRunProvider()
        let engine = try engine([provider])
        let run = Task { try await engine.run(request: textRequest) }
        for _ in 0 ..< 500 where !provider.hasEntered { try await Task.sleep(nanoseconds: 2_000_000) }

        let closed = Flag()
        let closing = Task {
            await engine.close()
            closed.set()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(closed.value, "close must wait for the run")

        provider.release()
        await closing.value
        XCTAssertTrue(closed.value)
        let result = try await run.value
        XCTAssertEqual(result.output.text, "ok")
    }

    func testCallsAfterCloseRejectWithEngineClosed() async throws {
        let engine = try engine([MockStreamProvider(id: "p1")])
        await engine.close()

        await assertEngineClosed { try await engine.run(request: textRequest) }
        await assertEngineClosed { try await engine.stream(request: textRequest) }
        await assertEngineClosed { try await engine.prepare() }
        await assertEngineClosed { try await engine.readArtifact(request: ArtifactReadRequest(artifactId: "x", maxBytes: nil, offset: nil)) }
        await assertEngineClosed { try await engine.speak(SpeakOptions("Hallo", locale: "de-AT")) }
        await assertEngineClosed { try await engine.generateSpeech(GenerateSpeechOptions(SpeakOptions("Hallo", locale: "de-AT"))) }
        // checkCapabilities cannot throw on Swift; a closed engine reports no providers.
        let snapshots = await engine.checkCapabilities()
        XCTAssertTrue(snapshots.isEmpty)
        // disposeArtifact is a no-op that does not throw.
        await engine.disposeArtifact(artifact: MediaArtifact(byteLength: nil, destinationRef: nil, durationMs: nil, id: "x", lifetime: .untilDisposed, mediaType: "audio/wav", owner: .engine))
    }

    func testConcurrentCloseClosesOnce() async throws {
        let provider = MockStreamProvider(id: "p1", script: [.waitForCancellation])
        let engine = try engine([provider])
        let run = try await engine.stream(request: textRequest)
        let collected = Task { try await drain(run) }
        await provider.waitUntilEntered()

        async let first: Void = engine.close()
        async let second: Void = engine.close()
        _ = await (first, second)
        await engine.close()

        assertSingleCancelledTerminal(try await collected.value)
    }

    func testCloseRacingStreamStartEndsInEngineClosedOrOneCancelledTerminal() async throws {
        for _ in 0 ..< 20 {
            let engine = try engine([MockStreamProvider(id: "p1", script: [.waitForCancellation])])
            let starting = Task { try await engine.stream(request: textRequest) }
            async let closing: Void = engine.close()
            let outcome = await starting.result
            await closing

            switch outcome {
            case .failure(let error):
                XCTAssertEqual((error as? IndeRunException)?.details?["code"]?.value as? String, "engine_closed")
            case .success(let run):
                assertSingleCancelledTerminal(try await drain(run))
            }
            await assertEngineClosed { try await engine.stream(request: textRequest) }
        }
    }

    func testAStreamNeverConsumedIsCancelledAndAnyLaterReadSeesOneCancelledTerminal() async throws {
        let provider = MockStreamProvider(id: "p1", script: [.init(.delta(text: "a")), .waitForCancellation])
        let engine = try engine([provider])
        let run = try await engine.stream(request: textRequest)
        await provider.waitUntilEntered()

        await engine.close()

        assertSingleCancelledTerminal(try await drain(run))
    }

    func testAConsumerPausedBetweenEventsSeesOneCancelledTerminalAfterClose() async throws {
        let provider = MockStreamProvider(id: "p1", script: [.init(.delta(text: "a")), .waitForCancellation])
        let engine = try engine([provider])
        let run = try await engine.stream(request: textRequest)
        var iterator = run.events.makeAsyncIterator()
        var events: [StreamEvent] = []
        while let event = try await iterator.next() {
            events.append(event)
            if event.type == "content_delta" { break }
        }

        await engine.close()
        while let event = try await iterator.next() { events.append(event) }

        assertSingleCancelledTerminal(events)
    }

    func testCloseDisposesEngineOwnedArtifacts() async throws {
        let (world, _) = try neuralWorld(fallback: false)
        let result = try await world.engine.run(request: TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            speech: SpeechInput(locale: "de-DE", localeMatch: nil, text: "Hallo", voice: nil),
            delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: ["audio/wav"], mode: .artifact)
        ))
        let artifactId = try XCTUnwrap(result.output.artifact?.id)
        XCTAssertNotNil(world.engine.artifacts.bytes(artifactId: artifactId))

        await world.engine.close()

        XCTAssertNil(world.engine.artifacts.bytes(artifactId: artifactId))
    }

    func testCloseDoesNotCloseAnAppSuppliedRuntime() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let audio = FixtureAudioOutputService()
        let (a, _) = try neuralWorld(runtime: runtime, audio: audio)
        let (b, fallbackB) = try neuralWorld(runtime: runtime, audio: audio)

        await a.engine.close()
        let spoken = try await b.engine.speak(SpeakOptions("Hallo", locale: "de-DE", model: "chain")).result()
        XCTAssertNotEqual(spoken.finishReason, .cancelled)
        XCTAssertEqual(spoken.provenance?.providerId, b.neuralId)
        XCTAssertEqual(fallbackB.callCount, 0)

        await runtime.close()
        let after = try await b.engine.speak(SpeakOptions("Hallo", locale: "de-DE", model: "chain")).result()
        XCTAssertEqual(after.provenance?.providerId, "fallback")
        XCTAssertEqual(fallbackB.callCount, 1)
        // A closed runtime reports itself unavailable, so routing skips the neural provider.
        let rejection = try XCTUnwrap(after.provenance?.routeRejections.first)
        XCTAssertEqual(rejection.providerId, b.neuralId)
        XCTAssertEqual(rejection.codes, [Code.capabilityUnavailable])
    }

    // MARK: - World

    private struct NeuralWorld {
        let engine: IndeRun
        let neuralId: String
    }

    private func neuralWorld(
        runtime: FixtureNeuralSpeechRuntime = FixtureNeuralSpeechRuntime(),
        audio: FixtureAudioOutputService = FixtureAudioOutputService(),
        fallback: Bool = true
    ) throws -> (NeuralWorld, MockStreamProvider) {
        let package = try Self.loadPackage()
        let neural = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: runtime))
        let registry = ProviderRegistry()
        try registry.register(neural)
        let fake = MockStreamProvider(
            id: "fallback",
            script: [.init(.result(output: TaskOutput(playback: PlaybackOutput(timing: nil)), finishReason: .stop))],
            task: .textToSpeech
        )
        if fallback { try registry.register(fake) }
        let engine = IndeRun(
            registry: registry,
            hostServices: host(audio: audio),
            modelProfiles: try ModelProfiles(["chain": [neural.id] + (fallback ? ["fallback"] : [])])
        )
        return (NeuralWorld(engine: engine, neuralId: neural.id), fake)
    }

    private static func loadPackage() throws -> ModelPackage {
        struct Catalog: Decodable { let package: ModelPackage }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("contracts/fixtures/speech/neural-speech-lifecycle.json")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).package
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
