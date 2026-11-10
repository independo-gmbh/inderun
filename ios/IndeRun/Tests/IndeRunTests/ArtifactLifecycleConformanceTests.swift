import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

// MARK: - Artifact store conformance

/// The Apple half of the cross-SDK artifact-store catalog
/// (`contracts/fixtures/execution/artifact-lifecycle.json`, ADR 017). One handler per case id;
/// `testImplementsEveryCaseInTheSharedCatalogAndNoOthers` fails when the handler ids and the
/// catalog ids differ. Mirrors `artifacts.conformance.test.ts`.
final class ArtifactLifecycleConformanceTests: XCTestCase {
    // MARK: Catalog

    private struct PartialReadRequest: Decodable {
        var artifactId: String?
        var offset: Int?
        var maxBytes: Int?
    }

    private struct ReadExpectation: Decodable {
        let request: PartialReadRequest
        let offset: Int
        let length: Int
        let totalBytes: Int
        let done: Bool
    }

    private struct ReadRejection: Decodable {
        let request: PartialReadRequest
        let errorClass: String
        var retryable: Bool?
        var code: String?
        var validationIssuePath: String?
    }

    /// The artifact fields the catalog compares exactly; `id` is only checked for presence.
    private struct ArtifactFields: Decodable, Equatable {
        let mediaType: String
        let owner: String
        let lifetime: String
        var byteLength: Int?
        var durationMs: Double?
        var destinationRef: String?
    }

    private struct RunRejection: Decodable {
        let errorClass: String
        var code: String?
    }

    private struct DestinationWrite: Decodable, Equatable {
        let destinationRef: String
        let mediaType: String
        let byteLength: Int
        let bytesMatchPattern: Bool
    }

    private struct TerminalExpectation: Decodable {
        var outcome: String?
        var absentOutput: Bool?
    }

    private struct Expectations: Decodable {
        var output: ArtifactFields?
        var reads: [ReadExpectation]?
        var readRejects: [ReadRejection]?
        var runRejectsWith: RunRejection?
        var runs: [String]?
        var providerCallCounts: [String: Int]?
        var attempts: [[String]]?
        var providerObservedCodes: [String: [String]]?
        var finishedReadable: [String: [Bool]]?
        var terminal: TerminalExpectation?
        var maxSerializedEventBytes: Int?
        var rejectsBeforeRouting: RunRejection?
        var destinationWrites: [DestinationWrite]?
    }

    private struct CatalogCase: Decodable {
        let id: String
        var mode: String?
        let expect: Expectations
    }

    private struct Catalog: Decodable {
        let cases: [CatalogCase]
    }

    private static func repositoryRoot() -> URL {
        // .../ios/IndeRun/Tests/IndeRunTests/ArtifactLifecycleConformanceTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCatalog() throws -> Catalog {
        let url = Self.repositoryRoot()
            .appendingPathComponent("contracts/fixtures/execution/artifact-lifecycle.json")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    // MARK: Tests

    func testImplementsEveryCaseInTheSharedCatalogAndNoOthers() throws {
        let catalogIds = try loadCatalog().cases.map(\.id).sorted()
        XCTAssertFalse(catalogIds.isEmpty)
        XCTAssertEqual(Set(catalogIds).count, catalogIds.count, "duplicate case id in the catalog")
        XCTAssertEqual(handlers.keys.sorted(), catalogIds)
    }

    func testMatchesTheSharedArtifactCatalog() async throws {
        for catalogCase in try loadCatalog().cases {
            guard let handler = handlers[catalogCase.id] else {
                XCTFail("no handler for catalog case '\(catalogCase.id)'")
                continue
            }
            try await check(label: catalogCase.id, expected: catalogCase.expect, observed: try await handler())
        }
    }

    // MARK: Observation

    private struct Observation {
        let engine: IndeRun
        var fakes: [ArtifactFake] = []
        var output: TaskOutput?
        var rejection: IndeRunException?
        var attempts: [[String]]?
        var runOutcomes: [String]?
        var events: [StreamEvent]?
        var destinationWrites: [RecordingDestinations.Write]?
    }

    // MARK: Handlers

    private typealias Handler = () async throws -> Observation

    private var handlers: [String: Handler] {
        [
            "destination_unsupported_refused_before_routing": { [self] in
                try await runCase(
                    [ArtifactFake(id: "p1", steps: [.write(10), .finish, .returnFinished(0)])],
                    request: Self.destinationRequest
                )
            },
            "destination_written_and_store_released": { [self] in
                let destinations = RecordingDestinations()
                var observed = try await runCase(
                    [ArtifactFake(id: "p1", steps: [.write(1000), .finish, .returnFinished(0)])],
                    destinations: destinations,
                    request: Self.destinationRequest
                )
                observed.destinationWrites = destinations.writes
                return observed
            },
            "cancel_during_destination_write_is_cancelled": { [self] in
                let destinations = RecordingDestinations(blockWrites: true)
                let fake = ArtifactFake(id: "p1", steps: [.write(10), .finish, .returnFinished(0)])
                let engine = try engine(with: [fake], destinations: destinations)
                let run = try await engine.stream(request: Self.destinationRequest)
                let collector = Task { try await Self.drain(run) }
                await destinations.waitUntilWriteStarted()
                run.cancel()
                destinations.release()
                let events = try await collector.value
                var observed = Observation(
                    engine: engine,
                    fakes: [fake],
                    output: events.first { $0.type == "terminal" }?.payload?.output,
                    events: events
                )
                observed.destinationWrites = destinations.writes
                return observed
            },
            "destination_write_failure_is_terminal": { [self] in
                try await runCase(
                    [
                        ArtifactFake(id: "p1", steps: [.write(10), .finish, .returnFinished(0)]),
                        ArtifactFake(id: "p2", steps: [.write(10), .finish, .returnFinished(0)])
                    ],
                    destinations: RecordingDestinations(failWrites: true),
                    request: Self.destinationRequest
                )
            },
            "read_full": { [self] in
                try await runCase([
                    ArtifactFake(
                        id: "p1",
                        steps: [.write(1000), .finish, .returnFinished(0)],
                        spec: ArtifactSpec(mediaType: "audio/wav", durationMs: 500)
                    )
                ])
            },
            "chunked_reads_cover_bytes_once": { [self] in
                try await runCase([
                    ArtifactFake(id: "p1", steps: [.write(300), .write(300), .write(400), .finish, .returnFinished(0)])
                ])
            },
            "read_is_bounded_by_the_engine_limit": { [self] in
                try await runCase(
                    [ArtifactFake(id: "p1", steps: [.write(1000), .finish, .returnFinished(0)])],
                    limits: ArtifactLimits(maxReadBytes: 256)
                )
            },
            "repeated_reads_identical": { [self] in
                try await runCase([ArtifactFake(id: "p1", steps: [.write(1000), .finish, .returnFinished(0)])])
            },
            "read_at_end_is_empty_and_beyond_end_is_rejected": { [self] in
                try await runCase([ArtifactFake(id: "p1", steps: [.write(1000), .finish, .returnFinished(0)])])
            },
            "dispose_is_idempotent_then_not_found": { [self] in
                let observed = try await runCase([
                    ArtifactFake(id: "p1", steps: [.write(10), .finish, .returnFinished(0)])
                ])
                let artifact = try XCTUnwrap(observed.output?.artifact)
                await observed.engine.disposeArtifact(artifact: artifact)
                await observed.engine.disposeArtifact(artifact: artifact)
                return observed
            },
            "unknown_id_not_found": { [self] in
                Observation(engine: try engine(with: []))
            },
            "post_handoff_failure_is_terminal_and_disposes": { [self] in
                try await runCase([
                    ArtifactFake(id: "p1", steps: [.write(10), .finish, .fail]),
                    ArtifactFake(id: "p2", steps: [.write(10), .finish, .returnFinished(0)])
                ])
            },
            "stored_media_type_decides_the_match": { [self] in
                try await runCase([
                    ArtifactFake(
                        id: "p1",
                        steps: [.write(10), .finish, .returnFinishedClaiming("audio/wav")],
                        spec: ArtifactSpec(mediaType: "audio/mpeg")
                    ),
                    ArtifactFake(id: "p2", steps: [.write(10), .finish, .returnFinished(0)])
                ])
            },
            "too_large_is_pre_commit_and_falls_back": { [self] in
                try await runCase(
                    [
                        ArtifactFake(id: "p1", steps: [.write(101), .finish, .returnFinished(0)]),
                        ArtifactFake(id: "p2", steps: [.write(50), .finish, .returnFinished(0)])
                    ],
                    limits: ArtifactLimits(maxArtifactBytes: 100)
                )
            },
            "store_full_refuses_handoff_until_disposed": { [self] in
                let fake = ArtifactFake(id: "p1", steps: [.write(100), .finish, .returnFinished(0)])
                let engine = try engine(with: [fake], limits: ArtifactLimits(maxStoreBytes: 150))
                var outcomes: [String] = []
                var rejection: IndeRunException?
                let first = try await engine.run(request: Self.request)
                outcomes.append("succeeded")
                do {
                    _ = try await engine.run(request: Self.request)
                    outcomes.append("succeeded")
                } catch let error as IndeRunException {
                    rejection = error
                    outcomes.append("rejected")
                }
                await engine.disposeArtifact(artifact: try XCTUnwrap(first.output.artifact))
                do {
                    _ = try await engine.run(request: Self.request)
                    outcomes.append("succeeded")
                } catch {
                    outcomes.append("rejected")
                }
                return Observation(engine: engine, fakes: [fake], rejection: rejection, runOutcomes: outcomes)
            },
            "unreturned_artifacts_disposed": { [self] in
                try await runCase([
                    ArtifactFake(id: "p1", steps: [.write(10), .finish, .write(20), .finish, .returnFinished(1)])
                ])
            },
            "foreign_artifact_is_output_mismatch": { [self] in
                try await runCase([
                    ArtifactFake(id: "p1", steps: [.returnForged]),
                    ArtifactFake(id: "p2", steps: [.write(10), .finish, .returnFinished(0)])
                ])
            },
            "cancelled_stream_disposes_artifact": { [self] in
                let fake = ArtifactFake(id: "p1", steps: [.write(10), .finish, .waitForCancellation])
                let engine = try engine(with: [fake])
                let run = try await engine.stream(request: Self.request)
                let collector = Task { try await Self.drain(run) }
                await fake.waitUntilHandedOver()
                run.cancel()
                return Observation(engine: engine, fakes: [fake], events: try await collector.value)
            },
            "events_carry_no_media_bytes": { [self] in
                let fake = ArtifactFake(id: "p1", steps: [.write(1_048_576), .finish, .returnFinished(0)])
                let engine = try engine(with: [fake])
                let events = try await Self.drain(try await engine.stream(request: Self.request))
                let output = events.first { $0.type == "terminal" }?.payload?.output
                return Observation(engine: engine, fakes: [fake], output: output, events: events)
            }
        ]
    }

    // MARK: Helpers

    private static let request = makeSpeechRequest(
        delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: ["audio/wav"], mode: .artifact)
    )

    private static let destinationRequest = makeSpeechRequest(
        delivery: OutputDeliveryRequest(destinationRef: "dest_greeting", mediaTypes: ["audio/wav"], mode: .artifact)
    )

    private func engine(
        with fakes: [ArtifactFake],
        limits: ArtifactLimits = ArtifactLimits(),
        destinations: ArtifactDestinationService? = nil
    ) throws -> IndeRun {
        let registry = ProviderRegistry()
        for fake in fakes { try registry.register(fake) }
        return IndeRun(
            registry: registry,
            hostServices: HostServices(
                connectivity: MockConnectivityService(),
                clock: MockClockService(),
                artifactDestinations: destinations
            ),
            artifactLimits: limits
        )
    }

    private func runCase(
        _ fakes: [ArtifactFake],
        limits: ArtifactLimits = ArtifactLimits(),
        destinations: ArtifactDestinationService? = nil,
        request: TaskRequest = ArtifactLifecycleConformanceTests.request
    ) async throws -> Observation {
        let engine = try engine(with: fakes, limits: limits, destinations: destinations)
        do {
            let result = try await engine.run(request: request)
            return Observation(
                engine: engine,
                fakes: fakes,
                output: result.output,
                attempts: result.provenance?.attempts.map { [$0.providerId, $0.outcome.rawValue] }
            )
        } catch let error as IndeRunException {
            return Observation(
                engine: engine,
                fakes: fakes,
                rejection: error,
                attempts: error.provenance?.attempts.map { [$0.providerId, $0.outcome.rawValue] }
            )
        }
    }

    private static func drain(_ run: StreamRun) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in run.events {
            events.append(event)
        }
        return events
    }

    private func readRequest(_ partial: PartialReadRequest, artifactId: String) -> ArtifactReadRequest {
        ArtifactReadRequest(
            artifactId: partial.artifactId ?? artifactId,
            maxBytes: partial.maxBytes,
            offset: partial.offset
        )
    }

    // MARK: Assertions

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func check(label: String, expected: Expectations, observed: Observation) async throws {
        let engine = observed.engine
        let artifact = observed.output?.artifact

        if let output = expected.output {
            guard let artifact else {
                XCTFail("\(label): expected an artifact output")
                return
            }
            XCTAssertFalse(artifact.id.isEmpty, "\(label): artifact id")
            XCTAssertEqual(
                ArtifactFields(
                    mediaType: artifact.mediaType,
                    owner: artifact.owner.rawValue,
                    lifetime: artifact.lifetime.rawValue,
                    byteLength: artifact.byteLength,
                    durationMs: artifact.durationMs,
                    destinationRef: artifact.destinationRef
                ),
                output,
                "\(label): output"
            )
        }
        for read in expected.reads ?? [] {
            let chunk = try await engine.readArtifact(
                request: readRequest(read.request, artifactId: try XCTUnwrap(artifact?.id, label))
            )
            XCTAssertEqual(chunk.offset, read.offset, "\(label): read offset")
            XCTAssertEqual(chunk.bytes.count, read.length, "\(label): read length")
            XCTAssertEqual(chunk.totalBytes, read.totalBytes, "\(label): read totalBytes")
            XCTAssertEqual(chunk.done, read.done, "\(label): read done")
            XCTAssertEqual(chunk.bytes, pattern(start: read.offset, count: read.length), "\(label): read bytes")
        }
        for rejected in expected.readRejects ?? [] {
            do {
                _ = try await engine.readArtifact(
                    request: readRequest(rejected.request, artifactId: artifact?.id ?? "art_unknown")
                )
                XCTFail("\(label): expected readArtifact to throw")
            } catch let error as IndeRunException {
                XCTAssertEqual(error.errorClass.rawValue, rejected.errorClass, "\(label): read errorClass")
                if let retryable = rejected.retryable {
                    XCTAssertEqual(error.retryable, retryable, "\(label): read retryable")
                }
                if let code = rejected.code {
                    XCTAssertEqual(error.details?["code"]?.value as? String, code, "\(label): read code")
                }
                if let path = rejected.validationIssuePath {
                    let issues = error.details?["validationIssues"]?.value as? [[String: String]] ?? []
                    XCTAssertTrue(issues.contains { $0["path"] == path }, "\(label): validation issue \(path)")
                }
            }
        }
        if let runRejection = expected.runRejectsWith {
            guard let rejection = observed.rejection else {
                XCTFail("\(label): expected run() to throw")
                return
            }
            XCTAssertEqual(rejection.errorClass.rawValue, runRejection.errorClass, "\(label): run errorClass")
            if let code = runRejection.code {
                XCTAssertEqual(rejection.details?["code"]?.value as? String, code, "\(label): run code")
            }
        }
        if let runs = expected.runs {
            XCTAssertEqual(observed.runOutcomes, runs, "\(label): runs")
        }
        for (providerId, count) in expected.providerCallCounts ?? [:] {
            XCTAssertEqual(fake(providerId, in: observed)?.callCount, count, "\(label): \(providerId) calls")
        }
        if let attempts = expected.attempts {
            XCTAssertEqual(observed.attempts, attempts, "\(label): attempts")
        }
        for (providerId, codes) in expected.providerObservedCodes ?? [:] {
            XCTAssertEqual(fake(providerId, in: observed)?.observedCodes, codes, "\(label): \(providerId) codes")
        }
        for (providerId, readable) in expected.finishedReadable ?? [:] {
            var actual: [Bool] = []
            for finished in fake(providerId, in: observed)?.finished ?? [] {
                let chunk = try? await engine.readArtifact(
                    request: ArtifactReadRequest(artifactId: finished.id, maxBytes: nil, offset: nil)
                )
                actual.append(chunk != nil)
            }
            XCTAssertEqual(actual, readable, "\(label): \(providerId) finished readable")
        }
        if let terminal = expected.terminal {
            guard let payload = observed.events?.first(where: { $0.type == "terminal" })?.payload else {
                XCTFail("\(label): expected a terminal event")
                return
            }
            if let outcome = terminal.outcome {
                XCTAssertEqual(payload.outcome?.rawValue, outcome, "\(label): terminal outcome")
            }
            if terminal.absentOutput == true {
                XCTAssertNil(payload.output, "\(label): terminal output must be absent")
            }
        }
        if let beforeRouting = expected.rejectsBeforeRouting {
            guard let rejection = observed.rejection else {
                XCTFail("\(label): expected run() to throw")
                return
            }
            XCTAssertEqual(rejection.errorClass.rawValue, beforeRouting.errorClass, "\(label): errorClass")
            XCTAssertEqual(rejection.details?["code"]?.value as? String, beforeRouting.code, "\(label): code")
            XCTAssertEqual(observed.attempts ?? [], [], "\(label): no attempt before routing")
        }
        if let writes = expected.destinationWrites {
            XCTAssertEqual(
                (observed.destinationWrites ?? []).map { write in
                    DestinationWrite(
                        destinationRef: write.destinationRef,
                        mediaType: write.artifact.mediaType,
                        byteLength: write.bytes.count,
                        bytesMatchPattern: write.bytes == pattern(start: 0, count: write.bytes.count)
                    )
                },
                writes,
                "\(label): destination writes"
            )
        }
        if let maxBytes = expected.maxSerializedEventBytes {
            for event in observed.events ?? [] {
                let size = try JSONEncoder().encode(event).count
                XCTAssertLessThan(size, maxBytes, "\(label): '\(event.type)' event is \(size) bytes")
            }
        }
    }

    private func fake(_ providerId: String, in observed: Observation) -> ArtifactFake? {
        observed.fakes.first { $0.id == providerId }
    }
}

// MARK: - Fakes

/// A host artifact-destination service that accepts every reference and records each write,
/// or fails every write with an error naming a path the run's error must not repeat.
private final class RecordingDestinations: ArtifactDestinationService, @unchecked Sendable {
    struct Write {
        let destinationRef: String
        let artifact: MediaArtifact
        let bytes: Data
    }

    private let failWrites: Bool
    /// When set, a write waits for `release()` before it completes.
    private let blockWrites: Bool
    private let lock = NSLock()
    private var recorded: [Write] = []
    private var started = false
    private var released = false

    init(failWrites: Bool = false, blockWrites: Bool = false) {
        self.failWrites = failWrites
        self.blockWrites = blockWrites
    }

    var writes: [Write] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Waits until a write has begun. Bounded, so a broken path fails rather than hangs.
    func waitUntilWriteStarted() async {
        for _ in 0 ..< 500 where !lock.withLock({ started }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func release() {
        lock.withLock { released = true }
    }

    func accepts(destinationRef: String, mediaTypes: [String]?) async -> Bool {
        true
    }

    func write(destinationRef: String, artifact: MediaArtifact, bytes: Data) async throws {
        lock.withLock { started = true }
        if blockWrites {
            for _ in 0 ..< 500 where !lock.withLock({ released }) {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        if failWrites {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/private/dest_greeting"])
        }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Write(destinationRef: destinationRef, artifact: artifact, bytes: bytes))
    }
}

/// byte[i] = i % 251 over [start, start + count).
private func pattern(start: Int, count: Int) -> Data {
    Data((0 ..< count).map { UInt8((start + $0) % 251) })
}

/// A `text_to_speech` provider scripted in the catalog's vocabulary, recording what it
/// observed. Mirrors `ArtifactFake` in `artifacts.conformance.test.ts`.
private final class ArtifactFake: StreamingProviderAdapter, @unchecked Sendable {
    enum Step: Sendable {
        /// Writes `n` pattern bytes into the current artifact, starting one if none is open.
        case write(Int)
        /// Finishes the current artifact (starting an empty one if none is open).
        case finish
        /// Returns the artifact output with the `index`th artifact this call finished.
        case returnFinished(Int)
        /// Returns the first artifact this call finished, relabelled with another media type.
        case returnFinishedClaiming(String)
        /// Returns an artifact output with an id the engine never issued.
        case returnForged
        /// Throws `Unavailable`.
        case fail
        /// Waits until the stream is cancelled, then ends without output.
        case waitForCancellation
    }

    let id: String
    private let steps: [Step]
    private let spec: ArtifactSpec
    private let lock = NSLock()
    private var calls = 0
    private var finishedReferences: [MediaArtifact] = []
    private var codes: [String] = []
    private var handedOver = false

    init(id: String, steps: [Step], spec: ArtifactSpec = ArtifactSpec(mediaType: "audio/wav")) {
        self.id = id
        self.steps = steps
        self.spec = spec
    }

    var callCount: Int { locked { calls } }
    /// The references `finish()` returned, in order.
    var finished: [MediaArtifact] { locked { finishedReferences } }
    /// `details.code` of every error the writer threw at this provider, in order.
    var observedCodes: [String] { locked { codes } }

    /// Waits until an artifact has been handed over. Bounded, so a broken path fails rather
    /// than hangs.
    func waitUntilHandedOver() async {
        for _ in 0 ..< 500 where !locked({ handedOver }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true,
                streaming: true,
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
                    interaction: ProviderTaskInteraction(run: true, stream: true),
                    cancel: .hard,
                    outputs: [ProviderTaskOutput(delivery: .artifact, mediaTypes: ["audio/wav"])],
                    locales: ["de-AT"]
                )
            ]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        guard let output = try await play(artifacts: context.artifacts, cancellation: nil) else {
            throw createInternal(message: "the script ended without an output")
        }
        return TaskResult(
            runId: context.runId,
            output: output,
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if let output = try await self.play(artifacts: context.artifacts, cancellation: context.cancellation) {
                        continuation.yield(.result(output: output))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func play(artifacts: any ArtifactSink, cancellation: StreamCancellationToken?) async throws -> TaskOutput? {
        // `returnFinished` indexes the artifacts this call finished.
        let firstOfCall = locked { () -> Int in
            calls += 1
            return finishedReferences.count
        }
        var writer: (any ArtifactWriter)?
        var written = 0
        for step in steps {
            switch step {
            case let .write(count):
                let current = writer ?? artifacts.create(spec: spec)
                writer = current
                try observe { try current.write(pattern(start: written, count: count)) }
                written += count
            case .finish:
                let current = writer ?? artifacts.create(spec: spec)
                let reference = try observe { try current.finish() }
                writer = nil
                written = 0
                locked {
                    finishedReferences.append(reference)
                    handedOver = true
                }
            case let .returnFinished(index):
                return TaskOutput(artifact: locked { finishedReferences[firstOfCall + index] })
            case let .returnFinishedClaiming(mediaType):
                var claimed = locked { finishedReferences[firstOfCall] }
                claimed.mediaType = mediaType
                return TaskOutput(artifact: claimed)
            case .returnForged:
                return TaskOutput(artifact: MediaArtifact(
                    byteLength: nil,
                    destinationRef: nil,
                    durationMs: nil,
                    id: "art_forged",
                    lifetime: .untilDisposed,
                    mediaType: "audio/wav",
                    owner: .engine
                ))
            case .fail:
                throw createUnavailable(message: "provider failed after handoff")
            case .waitForCancellation:
                for _ in 0 ..< 500 where cancellation?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                return nil
            }
        }
        return nil
    }

    private func observe<T>(_ action: () throws -> T) throws -> T {
        do {
            return try action()
        } catch let error as IndeRunException {
            if let code = error.details?["code"]?.value as? String {
                locked { codes.append(code) }
            }
            throw error
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
