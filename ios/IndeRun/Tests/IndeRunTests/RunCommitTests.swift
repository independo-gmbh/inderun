import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// What a fake speech provider does in `run()`, given the context the engine handed it.
private typealias Behaviour = @Sendable (RunContext) async throws -> TaskOutput

/// A run-only `text_to_speech` provider whose output comes from a `Behaviour`, recording each
/// attempt in `calls`.
private final class SpeechRunProvider: ProviderAdapter, @unchecked Sendable {
    let id: String
    let behaviour: Behaviour
    let outputs: [ProviderTaskOutput]
    let calls: CallLog

    init(
        id: String,
        outputs: [ProviderTaskOutput] = [ProviderTaskOutput(delivery: .playback)],
        calls: CallLog,
        behaviour: @escaping Behaviour
    ) {
        self.id = id
        self.outputs = outputs
        self.calls = calls
        self.behaviour = behaviour
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .systemService,
            supports: ProviderSupports(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .hard,
            tasks: ["text_to_speech"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_speech",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(run: true, stream: false),
                    cancel: .hard,
                    outputs: outputs,
                    locales: ["de-AT"]
                )
            ]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        calls.append(id)
        return TaskResult(
            runId: context.runId,
            output: try await behaviour(context),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var ids: [String] { lock.withLock { recorded } }

    func append(_ id: String) {
        lock.withLock { recorded.append(id) }
    }
}

/// The commit one attempt kept, and what calling it from a later attempt returned.
private final class KeptCommit: @unchecked Sendable {
    var commit: (@Sendable () -> Bool)?
    var lateResult: Bool?
}

/// Mode 1 (`run()`) half of the explicit commit rule (#245); the stream half is in the shared
/// conformance catalog. A text run never commits, so its fallback is exactly as before; a
/// playback run that committed owns its failure. Mirrors `engine.outputs.test.ts`.
final class RunCommitTests: XCTestCase {
    private static let played: Behaviour = { context in
        _ = context.commit()
        return TaskOutput(playback: PlaybackOutput(durationMs: 900))
    }

    private func engine(_ providers: [SpeechRunProvider]) throws -> IndeRun {
        let registry = ProviderRegistry()
        for provider in providers { try registry.register(provider) }
        return IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
    }

    private func runExpectingFailure(
        _ engine: IndeRun,
        _ request: TaskRequest = makeSpeechRequest()
    ) async throws -> IndeRunException {
        do {
            _ = try await engine.run(request: request)
            XCTFail("expected run() to throw")
            throw createInternal(message: "unreachable")
        } catch let error as IndeRunException {
            return error
        }
    }

    func testReturnsACommittedPlaybackResultWithItsProvenance() async throws {
        let calls = CallLog()
        let engine = try engine([SpeechRunProvider(id: "p1", calls: calls, behaviour: Self.played)])

        let result = try await engine.run(request: makeSpeechRequest())

        XCTAssertEqual(result.output.type, .playback)
        XCTAssertEqual(result.output.playback?.durationMs, 900)
        let attempts = try XCTUnwrap(result.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.providerId), ["p1"])
        XCTAssertEqual(attempts.map(\.outcome), [.succeeded])
        XCTAssertEqual(attempts.map(\.committed), [true])
    }

    func testFallsBackWhenPlaybackFailsBeforeCommit() async throws {
        let calls = CallLog()
        let engine = try engine([
            SpeechRunProvider(id: "p1", calls: calls) { _ in
                throw createUnavailable(message: "no audio session")
            },
            SpeechRunProvider(id: "p2", calls: calls, behaviour: Self.played)
        ])

        let result = try await engine.run(request: makeSpeechRequest())

        XCTAssertEqual(calls.ids, ["p1", "p2"])
        let attempts = try XCTUnwrap(result.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.providerId), ["p1", "p2"])
        XCTAssertEqual(attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(attempts.map(\.errorClass), [.Unavailable, nil])
        XCTAssertEqual(attempts.map(\.committed), [nil, true])
    }

    func testNeverFallsBackOncePlaybackCommittedAndAttributesTheFailure() async throws {
        let calls = CallLog()
        let engine = try engine([
            SpeechRunProvider(id: "p1", calls: calls) { context in
                _ = context.commit()
                throw createUnavailable(message: "audio device lost")
            },
            SpeechRunProvider(id: "p2", calls: calls, behaviour: Self.played)
        ])

        let error = try await runExpectingFailure(engine)

        XCTAssertEqual(calls.ids, ["p1"])
        XCTAssertEqual(error.errorClass, .Unavailable)
        XCTAssertEqual(error.provenance?.providerId, "p1")
        let attempts = try XCTUnwrap(error.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.providerId), ["p1"])
        XCTAssertEqual(attempts.map(\.outcome), [.failed])
        XCTAssertEqual(attempts.map(\.committed), [true])
    }

    func testRefusesACommitFromAnAttemptTheRunHasAlreadyLeft() async throws {
        let calls = CallLog()
        let kept = KeptCommit()
        let engine = try engine([
            SpeechRunProvider(id: "p1", calls: calls) { context in
                kept.commit = context.commit
                throw createUnavailable(message: "no audio session")
            },
            SpeechRunProvider(id: "p2", calls: calls) { context in
                // p1's callback fires while p2 runs: p1 must not start audio now.
                kept.lateResult = kept.commit?()
                return try await Self.played(context)
            }
        ])

        let result = try await engine.run(request: makeSpeechRequest())

        XCTAssertEqual(calls.ids, ["p1", "p2"])
        XCTAssertEqual(kept.lateResult, false)
        let attempts = try XCTUnwrap(result.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(attempts.map(\.committed), [nil, true])
    }

    func testTreatsAnOutputOfTheWrongKindAsAProviderFault() async throws {
        let calls = CallLog()
        let engine = try engine([
            SpeechRunProvider(id: "p1", calls: calls) { _ in TaskOutput(text: "Hallo") }
        ])

        let error = try await runExpectingFailure(engine)

        XCTAssertEqual(error.errorClass, .Internal)
        XCTAssertEqual(error.details?["code"]?.value as? String, "output_mismatch")
    }

    func testRejectsAnArtifactWhoseMediaTypeTheRequestDoesNotAccept() async throws {
        let calls = CallLog()
        let artifact = TaskOutput(artifact: MediaArtifact(
            byteLength: nil,
            durationMs: nil,
            id: "art_1",
            lifetime: .untilDisposed,
            mediaType: "audio/mpeg",
            owner: .engine
        ))
        let engine = try engine([
            SpeechRunProvider(
                id: "p1",
                outputs: [ProviderTaskOutput(delivery: .artifact, mediaTypes: ["audio/wav", "audio/mpeg"])],
                calls: calls
            ) { _ in artifact }
        ])

        let error = try await runExpectingFailure(
            engine,
            makeSpeechRequest(delivery: OutputDeliveryRequest(mediaTypes: ["audio/wav"], mode: .artifact))
        )

        XCTAssertEqual(error.details?["code"]?.value as? String, "output_mismatch")
    }

    func testAcceptsAnArtifactMediaTypeIgnoringParametersAndCase() async throws {
        let calls = CallLog()
        let engine = try engine([
            SpeechRunProvider(
                id: "p1",
                outputs: [ProviderTaskOutput(delivery: .artifact, mediaTypes: ["audio/L16"])],
                calls: calls
            ) { context in
                let writer = context.artifacts.create(spec: ArtifactSpec(mediaType: "Audio/L16; rate=22050"))
                try writer.write(Data([1, 2, 3, 4]))
                return TaskOutput(artifact: try writer.finish())
            }
        ])

        let result = try await engine.run(
            request: makeSpeechRequest(delivery: OutputDeliveryRequest(mediaTypes: ["audio/l16"], mode: .artifact))
        )

        let artifact = try XCTUnwrap(result.output.artifact)
        XCTAssertEqual(artifact.mediaType, "Audio/L16; rate=22050")
        XCTAssertEqual(artifact.byteLength, 4)
        XCTAssertTrue(artifact.id.hasPrefix("art_"))
    }
}
