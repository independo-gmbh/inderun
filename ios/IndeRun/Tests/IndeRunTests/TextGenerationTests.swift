import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// An `IndeRunApi` that records requests and answers with a fixed result or a scripted event
/// sequence: the facade is tested against the interface, not an engine.
private final class FakeApi: IndeRunApi, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [TaskRequest] = []
    private var recordedCancels: [String?] = []
    let result: TaskResult?
    let events: [StreamEvent]
    let source: AsyncThrowingStream<StreamEvent, Error>?

    init(
        result: TaskResult? = nil,
        events: [StreamEvent] = [],
        source: AsyncThrowingStream<StreamEvent, Error>? = nil
    ) {
        self.result = result
        self.events = events
        self.source = source
    }

    var requests: [TaskRequest] { lock.withLock { recordedRequests } }
    var cancels: [String?] { lock.withLock { recordedCancels } }

    func run(request: TaskRequest) async throws -> TaskResult {
        lock.withLock { recordedRequests.append(request) }
        return try XCTUnwrap(result)
    }

    func stream(request: TaskRequest) async throws -> StreamRun {
        lock.withLock { recordedRequests.append(request) }
        let events = events
        return StreamRun(
            handle: StreamRunHandle(providerId: "p1", runId: "run_1", schemaVersion: .the10, startedAt: 0),
            events: source ?? AsyncThrowingStream { continuation in
                events.forEach { continuation.yield($0) }
                continuation.finish()
            },
            cancel: { [weak self] reason in self?.lock.withLock { self?.recordedCancels.append(reason) } }
        )
    }

    func checkCapabilities() async -> [ProviderCapabilitySnapshot] { [] }

    func readArtifact(request: ArtifactReadRequest) async throws -> ArtifactChunk {
        throw createInternal(message: "the text facade never reads artifacts")
    }

    func disposeArtifact(artifact: MediaArtifact) async {}
}

final class TextGenerationTests: XCTestCase {
    // MARK: - Shared facade vectors

    private struct Fixture: Decodable {
        let cases: [Vector]
    }

    private struct Vector: Decodable {
        let id: String
        let options: [String: AnyDecodable]
        let expected: AnyDecodable
    }

    /// Just enough of a JSON value to rebuild the options and compare requests structurally.
    private struct AnyDecodable: Decodable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let array = try? container.decode([AnyDecodable].self) {
                value = array.map(\.value)
            } else {
                value = try container.decode([String: AnyDecodable].self).mapValues(\.value)
            }
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/facade/text-generation.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func options(from raw: [String: Any]) throws -> TextGenerationOptions {
        let input: TextInput
        if let prompt = raw["prompt"] as? String {
            input = .prompt(prompt)
        } else {
            let messages = try XCTUnwrap(raw["messages"] as? [[String: Any]])
            input = .messages(try messages.map { message in
                Message(
                    role: try XCTUnwrap(Role(rawValue: try XCTUnwrap(message["role"] as? String))),
                    content: try XCTUnwrap(message["content"] as? String)
                )
            })
        }
        let execution = (raw["execution"] as? [String: Any]).map { execution in
            TextExecutionOptions(
                privacy: (execution["privacy"] as? String).flatMap(Privacy.init(rawValue:)),
                cloud: (execution["cloud"] as? String).flatMap(Cloud.init(rawValue:)),
                timeoutMs: execution["timeoutMs"] as? Int,
                optimizeFor: (execution["optimizeFor"] as? String).flatMap(OptimizeFor.init(rawValue:))
            )
        }
        let telemetry = (raw["telemetry"] as? [String: Any]).map { telemetry in
            TaskRequestTelemetry(
                consent: telemetry["consent"] as? Bool,
                level: (telemetry["level"] as? String).flatMap(Level.init(rawValue:)),
                tags: telemetry["tags"] as? [String: String]
            )
        }
        return TextGenerationOptions(
            input,
            model: raw["model"] as? String,
            system: raw["system"] as? String,
            maxOutputTokens: raw["maxOutputTokens"] as? Int,
            temperature: (raw["temperature"] as? Double) ?? (raw["temperature"] as? Int).map(Double.init),
            topP: (raw["topP"] as? Double) ?? (raw["topP"] as? Int).map(Double.init),
            stop: raw["stop"] as? [String],
            seed: raw["seed"] as? Int,
            execution: execution,
            authContextRef: raw["authContextRef"] as? String,
            telemetry: telemetry,
            requestId: raw["requestId"] as? String
        )
    }

    func testMatchesTheSharedFacadeVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty)
        for vector in fixture.cases {
            let request = try options(from: vector.options.mapValues(\.value)).taskRequest()
            let encoded = try JSONSerialization.jsonObject(with: try request.jsonData()) as? NSDictionary
            let expected = vector.expected.value as? NSDictionary
            XCTAssertEqual(encoded, expected, vector.id)
        }
    }

    // MARK: - generateText

    func testGenerateTextRunsTheCanonicalRequestAndSummarizesTheResult() async throws {
        let taskResult = TaskResult(
            runId: "run_1",
            output: TaskOutput(text: "Hello"),
            finishReason: .stop,
            usage: TaskResultUsage(inputTokens: nil, outputTokens: nil, totalTokens: 3),
            telemetry: TaskResultTelemetry(providerUsed: "p1", totalMs: 5)
        )
        let api = FakeApi(result: taskResult)
        let options = TextGenerationOptions(.prompt("Hi"), model: "smart")

        let generated = try await api.generateText(options)

        XCTAssertEqual(api.requests.first?.modelProfile, "smart")
        XCTAssertEqual(api.requests.first?.prompt, "Hi")
        XCTAssertEqual(generated.text, "Hello")
        XCTAssertEqual(generated.finishReason, .stop)
        XCTAssertEqual(generated.usage?.totalTokens, 3)
        XCTAssertEqual(generated.runId, "run_1")
    }

    func testGenerateTextMatchesADirectRunOnARealEngine() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockProvider(id: "local_p", type: .local))
        let engine = IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
        let options = TextGenerationOptions(.prompt("Hi"), requestId: "req-1")

        let viaFacade = try await engine.generateText(options)
        let direct = try await engine.run(request: options.taskRequest())

        XCTAssertEqual(viaFacade.text, direct.output.text)
        XCTAssertEqual(viaFacade.runId, direct.runId)
        XCTAssertEqual(viaFacade.provenance?.providerId, direct.provenance?.providerId)
        XCTAssertEqual(viaFacade.provenance?.attempts.count, direct.provenance?.attempts.count)
    }

    // MARK: - streamText

    private func event(_ type: String, _ payload: Payload, sequence: Int) -> StreamEvent {
        StreamEvent(
            payload: payload,
            runId: "run_1",
            schemaVersion: .the10,
            sequence: sequence,
            timestamp: 0,
            type: type
        )
    }

    private func terminal(_ outcome: StreamTerminalOutcome, sequence: Int) -> StreamEvent {
        event("terminal", Payload(terminalOutcome: outcome), sequence: sequence)
    }

    private func provenance(_ outcome: AttemptOutcome) -> ExecutionProvenance {
        ExecutionProvenance(
            attemptCount: 1,
            attempts: [ExecutionProvenanceAttempt(committed: nil, errorClass: nil, outcome: outcome, providerId: "p1")],
            configuredModel: nil,
            fallbackOccurred: false,
            locality: .onDevice,
            modelProfile: "auto",
            providerId: "p1",
            reportedModel: nil,
            routeRejections: [],
            schemaVersion: .the10
        )
    }

    private func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
        var items: [T] = []
        for try await item in stream { items.append(item) }
        return items
    }

    func testStreamTextExposesIncrementsEventsAndResultInAnyOrder() async throws {
        let events = [
            event("content_delta", .content(text: "Hel"), sequence: 0),
            event("content_delta", .content(text: "lo"), sequence: 1),
            terminal(.completed(
                runId: "run_1",
                finalText: "Hello",
                finishReason: .stop,
                usage: nil,
                telemetry: StreamTerminalOutcomeTelemetry(providerUsed: "p1", totalMs: 1),
                provenance: provenance(.succeeded)
            ), sequence: 2)
        ]
        let stream = try await FakeApi(events: events).streamText(TextGenerationOptions(.prompt("Hi")))

        let result = try await stream.result()
        let text = try await collect(stream.textStream)
        let full = try await collect(stream.fullStream)

        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.finishReason, .stop)
        XCTAssertEqual(result.provenance?.providerId, "p1")
        XCTAssertEqual(text, ["Hel", "lo"])
        XCTAssertEqual(full.map(\.sequence), [0, 1, 2])
    }

    func testStreamTextTurnsAnExtendingSnapshotIntoTheNewSuffix() async throws {
        let events = [
            event("content_snapshot", .content(text: "Loc"), sequence: 0),
            event("content_snapshot", .content(text: "Local first"), sequence: 1),
            terminal(.completed(
                runId: "run_1", finalText: "Local first", finishReason: nil, usage: nil,
                telemetry: StreamTerminalOutcomeTelemetry(providerUsed: "p1", totalMs: 1),
                provenance: provenance(.succeeded)
            ), sequence: 2)
        ]
        let stream = try await FakeApi(events: events).streamText(TextGenerationOptions(.prompt("Hi")))

        let text = try await collect(stream.textStream)
        XCTAssertEqual(text, ["Loc", "al first"])
    }

    func testStreamTextEndsTheTextViewWhenDeliveredTextIsRetracted() async throws {
        let events = [
            event("content_snapshot", .content(text: "Draft"), sequence: 0),
            event("content_snapshot", .content(text: ""), sequence: 1),
            terminal(.completed(
                runId: "run_1", finalText: "", finishReason: nil, usage: nil,
                telemetry: StreamTerminalOutcomeTelemetry(providerUsed: "p1", totalMs: 1),
                provenance: provenance(.succeeded)
            ), sequence: 2)
        ]
        let stream = try await FakeApi(events: events).streamText(TextGenerationOptions(.prompt("Hi")))

        do {
            _ = try await collect(stream.textStream)
            XCTFail("Expected the text view to end on retraction")
        } catch is TextStreamRetractedError {}
        let result = try await stream.result()
        XCTAssertEqual(result.text, "")
    }

    func testStreamTextThrowsTheRunsErrorWithItsProvenance() async throws {
        let failed = provenance(.failed)
        let events = [
            event("content_delta", .content(text: "partial"), sequence: 0),
            terminal(.failed(
                runId: "run_1",
                error: IndeRunError(errorClass: .RateLimited, message: "Slow down"),
                partialText: "partial",
                provenance: failed
            ), sequence: 1)
        ]
        let stream = try await FakeApi(events: events).streamText(TextGenerationOptions(.prompt("Hi")))

        do {
            _ = try await stream.result()
            XCTFail("Expected the run's error")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .RateLimited)
            XCTAssertEqual(error.runId, "run_1")
            XCTAssertEqual(error.provenance?.attempts.first?.outcome, .failed)
        }
        do {
            _ = try await collect(stream.textStream)
            XCTFail("Expected the text view to throw the run's error")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .RateLimited)
        }
    }

    func testStreamTextReturnsACancelledRunsPartialTextAndForwardsCancel() async throws {
        let api = FakeApi(events: [
            event("content_delta", .content(text: "one"), sequence: 0),
            terminal(.cancelled(
                runId: "run_1", partialText: "one", reason: "user stopped", provenance: provenance(.cancelled)
            ), sequence: 1)
        ])
        let stream = try await api.streamText(TextGenerationOptions(.prompt("Hi")))
        stream.cancel(reason: "user stopped")

        let result = try await stream.result()
        XCTAssertEqual(result.text, "one")
        XCTAssertEqual(result.finishReason, .cancelled)
        XCTAssertEqual(api.cancels, ["user stopped"])
    }

    func testStreamTextSettlesOnTheTerminalEventWhenTheSourceStaysOpen() async throws {
        let (source, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        continuation.yield(event("content_delta", .content(text: "Hi"), sequence: 0))
        continuation.yield(terminal(.completed(
            runId: "run_1", finalText: "Hi", finishReason: .stop, usage: nil,
            telemetry: StreamTerminalOutcomeTelemetry(providerUsed: "p1", totalMs: 1),
            provenance: provenance(.succeeded)
        ), sequence: 1))
        let stream = try await FakeApi(source: source).streamText(TextGenerationOptions(.prompt("Hi")))

        let result = try await stream.result()
        let text = try await collect(stream.textStream)
        let full = try await collect(stream.fullStream)

        XCTAssertEqual(result.text, "Hi")
        XCTAssertEqual(text, ["Hi"])
        XCTAssertEqual(full.map(\.type), ["content_delta", "terminal"])
    }

    func testStreamTextStopsWaitingWhenTheReaderIsCancelledOnAnIdleRun() async throws {
        let (source, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        let stream = try await FakeApi(source: source).streamText(TextGenerationOptions(.prompt("Hi")))

        let reader = Task { try await stream.result() }
        try await Task.sleep(nanoseconds: 10_000_000)
        reader.cancel()

        do {
            _ = try await reader.value
            XCTFail("Expected the cancelled reader to stop waiting")
        } catch is CancellationError {}
    }

    // MARK: - Shared forward-compatibility vectors

    private struct ForwardCompatFixture: Decodable {
        let cases: [ForwardCompatVector]
    }

    private struct ForwardCompatVector: Decodable {
        struct Expectation: Decodable {
            let textIncrements: [String]
            let text: String
            let fullStreamTypes: [String]
        }

        let id: String
        let events: [StreamEvent]
        let expect: Expectation
    }

    /// `StreamEvent.type` is an open set: an event type this revision does not know -- with or
    /// without a payload -- decodes, passes through `fullStream`, and is ignored by the text view.
    func testStreamTextMatchesTheSharedForwardCompatibilityVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/streaming/forward-compat-events.json")
        let fixture = try JSONDecoder().decode(ForwardCompatFixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty)

        for vector in fixture.cases {
            let stream = try await FakeApi(events: vector.events).streamText(TextGenerationOptions(.prompt("Hello")))

            let text = try await collect(stream.textStream)
            let full = try await collect(stream.fullStream)
            let result = try await stream.result()

            XCTAssertEqual(text, vector.expect.textIncrements, vector.id)
            XCTAssertEqual(full.map(\.type), vector.expect.fullStreamTypes, vector.id)
            XCTAssertEqual(result.text, vector.expect.text, vector.id)
        }
    }

    func testStreamTextRejectsBeforeThereIsARunExactlyAsStreamDoes() async throws {
        let engine = IndeRun(
            registry: ProviderRegistry(),
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )

        do {
            _ = try await engine.streamText(TextGenerationOptions(.prompt("Hi"), model: "unknown"))
            XCTFail("Expected validation to reject")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Internal)
        }
    }
}
