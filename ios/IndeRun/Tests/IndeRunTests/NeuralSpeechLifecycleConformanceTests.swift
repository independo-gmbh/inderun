import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift
import IndeRunNeuralSpeech

// MARK: - Neural speech lifecycle conformance

/// The Apple half of the cross-SDK neural speech catalog
/// (`contracts/fixtures/speech/neural-speech-lifecycle.json`). One handler per case id drives the
/// engine (or, for the direct-call cases, the provider) with the fixture runtime, the fixture
/// audio output and a scripted fallback; `testImplementsEveryCaseInTheSharedCatalogAndNoOthers`
/// fails when the handler ids and the catalog ids differ. Mirrors `lifecycle.conformance.test.ts`.
final class NeuralSpeechLifecycleConformanceTests: XCTestCase {
    func testImplementsEveryCaseInTheSharedCatalogAndNoOthers() throws {
        let catalogIds = try loadCatalog().cases.map(\.id).sorted()
        XCTAssertFalse(catalogIds.isEmpty)
        XCTAssertEqual(Set(catalogIds).count, catalogIds.count, "duplicate case id in the catalog")
        XCTAssertEqual(handlers.keys.sorted(), catalogIds)
    }

    func testMatchesEveryCaseInTheSharedCatalog() async throws {
        let catalog = try loadCatalog()
        for entry in catalog.cases {
            let handler = try XCTUnwrap(handlers[entry.id], "no handler for \(entry.id)")
            let observation = try await handler(entry, catalog.package)
            assertCase(entry, observation, sampleRate: try XCTUnwrap(catalog.package.speech?.sampleRate))
        }
    }
}

// MARK: - Catalog

private struct Expectations: Decodable {
    struct CommitAt: Decodable, Equatable {
        let sessionsOpened: Int
        let firstSessionWrites: Int
    }

    struct Sessions: Decodable {
        struct First: Decodable {
            let writes: Int?
            let stopped: Bool?
            let discardedFrames: String?
            let playedFrames: String?
        }

        let count: Int
        let first: First?
    }

    struct ExpectedError: Decodable {
        let errorClass: String
        let code: String
    }

    struct Timing: Decodable {
        let durationMsEquals: String?
        let firstChunkDefined: Bool?
        let firstAudioDefined: Bool?
    }

    struct Artifact: Decodable {
        struct Header: Decodable {
            let sampleRate: Int
            let channels: Int
            let bitsPerSample: Int
            let dataBytes: String
        }

        let mediaType: String
        let byteLengthEquals: String?
        let header: Header?
    }

    struct Runtime: Decodable {
        let synthesizeCalls: Int?
        let synthesizeCallsAtMost: Int?
        let prepareCalls: Int?
    }

    struct Order: Decodable {
        let secondOpensAfterFirstStops: Bool
    }

    struct Readiness: Decodable {
        let before: String?
        let after: String?
    }

    let outcome: String?
    let commitCount: Int?
    let commitAt: CommitAt?
    let sessions: Sessions?
    let fallbackAsked: Bool?
    let error: ExpectedError?
    let timing: Timing?
    let artifact: Artifact?
    let runtime: Runtime?
    let order: Order?
    let readiness: Readiness?
}

private struct CatalogCase: Decodable {
    let id: String
    let setup: String
    let timeoutMs: Int
    let expect: Expectations
}

private struct Catalog: Decodable {
    let package: ModelPackage
    let cases: [CatalogCase]
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/NeuralSpeechLifecycleConformanceTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func loadCatalog() throws -> Catalog {
    let url = repositoryRoot().appendingPathComponent("contracts/fixtures/speech/neural-speech-lifecycle.json")
    return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
}

private let text = "Hallo Welt. Wie geht es dir?"
private let locale = "de-AT"
/// The case's profile: [neural, fallback], or [neural] alone. A named profile, because `auto`
/// cannot be redefined and ranks equal targets by id, which would put "fallback" first.
private let profile = "neural"

// MARK: - World

/// Counts the frames the fixture runtime produces, without changing how it is consumed.
private final class CountingRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    let fixture: FixtureNeuralSpeechRuntime
    private let lock = NSLock()
    private var produced = 0

    init(_ fixture: FixtureNeuralSpeechRuntime) {
        self.fixture = fixture
    }

    var frames: Int { lock.withLock { produced } }

    func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.availability(modelPackage)
    }

    func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.prepare(modelPackage)
    }

    func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        let source = IteratorBox(fixture.synthesize(input).makeAsyncIterator())
        return AsyncThrowingStream(unfolding: { [self] in
            let chunk = try await source.next()
            if let chunk { lock.withLock { produced += chunk.samples.count } }
            return chunk
        })
    }
}

/// Pulls one element at a time, from whichever task asks.
private final class IteratorBox<Element>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Element, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<Element, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> Element? {
        var current = iterator
        defer { iterator = current }
        return try await current.next()
    }
}

/// The neural provider as the engine sees it, recording what it threw and how often the engine
/// entered `stream`.
private final class RecordingProvider: StreamingProviderAdapter, PreparableProviderAdapter, @unchecked Sendable {
    let inner: NeuralSpeechProvider
    private let lock = NSLock()
    private var thrown: [Error] = []
    private var streams = 0

    init(_ inner: NeuralSpeechProvider) {
        self.inner = inner
    }

    var errors: [Error] { lock.withLock { thrown } }
    var streamCalls: Int { lock.withLock { streams } }

    func describe() -> ProviderDescriptor { inner.describe() }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        await inner.capabilities(host: host)
    }

    func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error> {
        inner.prepare(context: context)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        do {
            return try await inner.run(request: request, context: context)
        } catch {
            record(error)
            throw error
        }
    }

    func stream(request: TaskRequest, context: ProviderStreamContext) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        lock.withLock { streams += 1 }
        let source = IteratorBox(inner.stream(request: request, context: context).makeAsyncIterator())
        return AsyncThrowingStream(unfolding: { [self] in
            do {
                return try await source.next()
            } catch {
                record(error)
                throw error
            }
        })
    }

    private func record(_ error: Error) {
        lock.withLock { thrown.append(error) }
    }
}

/// The fixture audio output, recording whether the first session had stopped when the second
/// opened, and optionally interrupting each session once its first write is taken.
private final class ObservedAudioOutput: AudioOutputService, @unchecked Sendable {
    let fixture = FixtureAudioOutputService()
    private let interruptsAfterFirstWrite: Bool
    private let lock = NSLock()
    private var stoppedAtSecondOpen: Bool?

    init(interruptsAfterFirstWrite: Bool) {
        self.interruptsAfterFirstWrite = interruptsAfterFirstWrite
    }

    var sessions: [FixtureAudioOutputSession] { fixture.sessions }
    var firstStoppedAtSecondOpen: Bool? { lock.withLock { stoppedAtSecondOpen } }

    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession {
        if let first = fixture.sessions.first, fixture.sessions.count == 1 {
            lock.withLock { stoppedAtSecondOpen = first.stopped }
        }
        let session = try await fixture.open(format: format)
        guard interruptsAfterFirstWrite, let opened = fixture.sessions.last else { return session }
        return InterruptingSession(opened)
    }
}

private final class InterruptingSession: AudioOutputSession, @unchecked Sendable {
    private let inner: FixtureAudioOutputSession

    init(_ inner: FixtureAudioOutputSession) {
        self.inner = inner
    }

    func write(_ samples: [Int16]) async throws {
        try await inner.write(samples)
        if inner.writes.count == 1 {
            inner.interrupt(
                createUnavailable(
                    message: "Audio output was interrupted by the system.",
                    details: ["code": JSONAny("audio_output_interrupted")]
                )
            )
        }
    }

    func drain() async throws { try await inner.drain() }
    func stop() { inner.stop() }
    func firstAudioMs() -> Double? { inner.firstAudioMs() }
}

/// One case's provider, its fixtures, and what they recorded.
private struct World {
    let runtime: CountingRuntime
    let neural: NeuralSpeechProvider
    let provider: RecordingProvider
    let audio: ObservedAudioOutput
    let fallback: MockStreamProvider?
    let hostServices: HostServices
    let engine: IndeRun

    var fixtureRuntime: FixtureNeuralSpeechRuntime { runtime.fixture }

    init(
        package: ModelPackage,
        runtime options: FixtureNeuralSpeechRuntimeOptions = FixtureNeuralSpeechRuntimeOptions(),
        audioOutput: Bool = true,
        fallback: Bool = true,
        interruptAfterFirstWrite: Bool = false
    ) throws {
        runtime = CountingRuntime(FixtureNeuralSpeechRuntime(options: options))
        neural = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: runtime))
        provider = RecordingProvider(neural)
        audio = ObservedAudioOutput(interruptsAfterFirstWrite: interruptAfterFirstWrite)
        hostServices = HostServices(
            connectivity: MockConnectivityService(),
            clock: MockClockService(),
            audioOutput: audioOutput ? audio : nil
        )
        let registry = ProviderRegistry()
        try registry.register(provider)
        if fallback {
            let fake = MockStreamProvider(
                id: "fallback",
                script: [.init(.result(output: TaskOutput(playback: PlaybackOutput(timing: nil)), finishReason: .stop))],
                task: .textToSpeech
            )
            try registry.register(fake)
            self.fallback = fake
        } else {
            self.fallback = nil
        }
        engine = IndeRun(
            registry: registry,
            hostServices: hostServices,
            modelProfiles: try ModelProfiles([profile: [neural.id] + (fallback ? ["fallback"] : [])])
        )
    }
}

// MARK: - Observations

private struct ObservedError: Equatable {
    let errorClass: String
    let code: String?

    init?(_ error: Error?) {
        guard let error = error as? IndeRunException else { return nil }
        errorClass = error.errorClass.rawValue
        code = error.details?["code"]?.value as? String
    }
}

private struct Observation {
    let world: World
    var outcome: String?
    var commitCount: Int?
    var commitAt: Expectations.CommitAt?
    var fallbackAsked: Bool?
    var error: ObservedError?
    var timing: PlaybackTiming?
    var artifact: (mediaType: String, bytes: Data)?
    var readiness: (before: String?, after: String?)?
    var secondOpensAfterFirstStops: Bool?

    init(_ world: World) {
        self.world = world
    }
}

/// What a speak run ended with, from the facade's result or rejection.
private struct Ending {
    let outcome: String
    let provenance: ExecutionProvenance?
    let error: IndeRunException?
}

private func ending(_ playback: SpeechPlayback, ms: Int) async throws -> Ending {
    do {
        let spoken = try await bounded(ms: ms, "speak") { try await playback.result() }
        return Ending(
            outcome: spoken.finishReason == .cancelled ? "cancelled" : "completed",
            provenance: spoken.provenance,
            error: nil
        )
    } catch let error as IndeRunException {
        return Ending(outcome: "error", provenance: error.provenance, error: error)
    }
}

/// Whether the engine's provenance reports the neural attempt committed.
private func neuralCommits(_ world: World, _ provenance: ExecutionProvenance?) -> Int {
    let attempt = provenance?.attempts.first { $0.providerId == world.neural.id }
    return attempt?.committed == true ? 1 : 0
}

private func speak(_ world: World, _ spoken: String = text) async throws -> SpeechPlayback {
    try await world.engine.speak(SpeakOptions(spoken, locale: locale, model: profile))
}

private func speechRequest(voice: ProviderVoice? = nil) -> TaskRequest {
    TaskRequest(
        task: TaskDescriptor(kind: .textToSpeech),
        speech: SpeechInput(locale: locale, localeMatch: nil, text: text, voice: nil),
        delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: nil, mode: .playback)
    )
}

/// A `commit()` for a direct provider call that records the fixture's state when first called.
private final class CommitSpy: @unchecked Sendable {
    private let audio: ObservedAudioOutput
    private let lock = NSLock()
    private var commits = 0
    private var recorded: Expectations.CommitAt?

    init(_ audio: ObservedAudioOutput) {
        self.audio = audio
    }

    var count: Int { lock.withLock { commits > 0 ? 1 : 0 } }
    var commitAt: Expectations.CommitAt? { lock.withLock { recorded } }

    var commit: @Sendable () -> Bool {
        { [self] in
            let sessions = audio.sessions
            let state = Expectations.CommitAt(
                sessionsOpened: sessions.count,
                firstSessionWrites: sessions.first?.writes.count ?? 0
            )
            lock.withLock {
                commits += 1
                if recorded == nil { recorded = state }
            }
            return true
        }
    }
}

/// The run `playback_commits_before_first_write` and `playback_reports_timing` share.
private func directPlayback(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package)
    let spy = CommitSpy(world.audio)
    let context = RunContext(runId: "direct-run", hostServices: world.hostServices, commit: spy.commit)
    let neural = world.neural
    let result = try await bounded(ms: entry.timeoutMs, "direct run") {
        try await neural.run(request: speechRequest(), context: context)
    }
    var observation = Observation(world)
    observation.commitCount = spy.count
    observation.commitAt = spy.commitAt
    observation.timing = result.output.playback?.timing
    return observation
}

private func readAll(_ engine: IndeRun, _ artifactId: String, ms: Int) async throws -> Data {
    var bytes = Data()
    while true {
        let offset = bytes.count
        let chunk = try await bounded(ms: ms, "readArtifact") {
            try await engine.readArtifact(request: ArtifactReadRequest(artifactId: artifactId, maxBytes: nil, offset: offset))
        }
        bytes.append(chunk.bytes)
        if chunk.done { return bytes }
    }
}

private func readiness(_ world: World) async -> String? {
    let snapshot = await world.engine.checkCapabilities().first { $0.providerId == world.neural.id }
    return snapshot?.capabilities.taskCapabilities?.first?.readiness?.rawValue
}

// MARK: - Handlers

private typealias Handler = (CatalogCase, ModelPackage) async throws -> Observation

/// One handler per catalog id; every wait is bounded by the case's `timeoutMs`.
private let handlers: [String: Handler] = [
    "playback_commits_before_first_write": directPlayback,
    "playback_reports_timing": directPlayback,
    "cancel_while_waiting_plays_nothing": cancelWhileWaitingPlaysNothing,
    "cancel_mid_stream_stops_audio_once": cancelMidStreamStopsAudioOnce,
    "missing_audio_output_refuses_before_commit": missingAudioOutputRefusesBeforeCommit,
    "unknown_voice_refused_before_commit": unknownVoiceRefusedBeforeCommit,
    "artifact_is_wav_of_the_samples": artifactIsWavOfTheSamples,
    "artifact_over_cap_fails_before_commit": artifactOverCapFailsBeforeCommit,
    "interruption_after_commit_fails_without_fallback": interruptionAfterCommitFailsWithoutFallback,
    "utterances_play_one_at_a_time": utterancesPlayOneAtATime,
    "capabilities_never_load": capabilitiesNeverLoad
]

private func cancelWhileWaitingPlaysNothing(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    // A's 30 chunks take 30 x 40 ms of wall time, so B is cancelled long before A ends even on a
    // loaded machine.
    let world = try World(package: package, runtime: FixtureNeuralSpeechRuntimeOptions(delayMs: 40))
    let textA = "Heute scheint die Sonne über den Bergen, und wir gehen raus."
    XCTAssertEqual(textA.count, 60)

    let first = try await speak(world, textA)
    try await waitUntil(ms: entry.timeoutMs, "A's first write") { (world.audio.sessions.first?.writes.count ?? 0) > 0 }
    let second = try await speak(world)
    try await waitUntil(ms: entry.timeoutMs, "B reaching the provider") { world.provider.streamCalls == 2 }
    XCTAssertEqual(world.audio.sessions.first?.stopped, false, "A ended before B was cancelled")
    second.cancel()

    let endA = try await ending(first, ms: entry.timeoutMs)
    let endB = try await ending(second, ms: entry.timeoutMs)
    XCTAssertEqual(endA.outcome, "completed")
    var observation = Observation(world)
    observation.outcome = endB.outcome
    observation.commitCount = neuralCommits(world, endB.provenance)
    return observation
}

private func cancelMidStreamStopsAudioOnce(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package, runtime: FixtureNeuralSpeechRuntimeOptions(delayMs: 5))
    let spoken = "Der Wind weht leise über die Wiesen am Rand des alten Dorfes, wo die Kinder spielen und lachen. "
        + "Am Abend kehren alle müde nach Hause zurück und erzählen einander von den kleinen Abenteuern des Tages!!"
    XCTAssertEqual(spoken.count, 200)

    // Driven through stream() rather than speak(), which stops reading at the first terminal.
    let run = try await world.engine.stream(request: SpeakOptions(spoken, locale: locale, model: profile).taskRequest())
    let consumed = Task { () -> [StreamEvent] in
        var terminals: [StreamEvent] = []
        for try await event in run.events where event.type == "terminal" {
            terminals.append(event)
        }
        return terminals
    }
    try await waitUntil(ms: entry.timeoutMs, "first write") { (world.audio.sessions.first?.writes.count ?? 0) > 0 }
    run.cancel()
    let terminals = try await bounded(ms: entry.timeoutMs, "stream") { try await consumed.value }

    XCTAssertEqual(terminals.count, 1)
    var observation = Observation(world)
    observation.outcome = terminals.first?.payload?.outcome?.rawValue
    observation.commitCount = neuralCommits(world, terminals.first?.payload?.provenance)
    return observation
}

private func missingAudioOutputRefusesBeforeCommit(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package, audioOutput: false)
    let end = try await ending(try await speak(world), ms: entry.timeoutMs)
    let attempt = end.provenance?.attempts.first { $0.providerId == world.neural.id }
    let error = ObservedError(world.provider.errors.first)
    // The provenance records the refusal's class; the provider's own error carries its code.
    XCTAssertEqual(attempt?.errorClass?.rawValue, error?.errorClass)
    var observation = Observation(world)
    observation.outcome = end.outcome
    observation.fallbackAsked = (world.fallback?.callCount ?? 0) > 0
    observation.commitCount = neuralCommits(world, end.provenance)
    observation.error = error
    return observation
}

private func unknownVoiceRefusedBeforeCommit(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package)
    let spy = CommitSpy(world.audio)
    let context = RunContext(
        runId: "direct-run",
        hostServices: world.hostServices,
        voice: ProviderVoice(locale: locale, id: "ghost"),
        commit: spy.commit
    )
    let neural = world.neural
    var observation = Observation(world)
    do {
        _ = try await bounded(ms: entry.timeoutMs, "direct run") {
            try await neural.run(request: speechRequest(), context: context)
        }
    } catch let error as IndeRunException {
        observation.error = ObservedError(error)
    }
    observation.commitCount = spy.count
    return observation
}

private func artifactIsWavOfTheSamples(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package)
    let engine = world.engine
    var observation = Observation(world)
    do {
        let generated = try await bounded(ms: entry.timeoutMs, "generateSpeech") {
            try await engine.generateSpeech(GenerateSpeechOptions(SpeakOptions(text, locale: locale, model: profile)))
        }
        observation.outcome = "completed"
        observation.commitCount = neuralCommits(world, generated.provenance)
        observation.artifact = (
            generated.artifact.mediaType,
            try await readAll(engine, generated.artifact.id, ms: entry.timeoutMs)
        )
    } catch let error as IndeRunException {
        observation.outcome = "error"
        observation.error = ObservedError(error)
    }
    return observation
}

private func artifactOverCapFailsBeforeCommit(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package, runtime: FixtureNeuralSpeechRuntimeOptions(msPerCharacter: 50000), fallback: false)
    let spoken = "Servus!"
    XCTAssertEqual(spoken.count, 7)
    let engine = world.engine
    var observation = Observation(world)
    do {
        _ = try await bounded(ms: entry.timeoutMs, "generateSpeech") {
            try await engine.generateSpeech(GenerateSpeechOptions(SpeakOptions(spoken, locale: locale, model: profile)))
        }
        observation.outcome = "completed"
    } catch let error as IndeRunException {
        observation.outcome = "error"
        observation.commitCount = neuralCommits(world, error.provenance)
        observation.error = ObservedError(error)
    }
    return observation
}

private func interruptionAfterCommitFailsWithoutFallback(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package, interruptAfterFirstWrite: true)
    let end = try await ending(try await speak(world), ms: entry.timeoutMs)
    var observation = Observation(world)
    observation.outcome = end.outcome
    observation.commitCount = neuralCommits(world, end.provenance)
    observation.fallbackAsked = (world.fallback?.callCount ?? 0) > 0
    observation.error = ObservedError(end.error)
    return observation
}

private func utterancesPlayOneAtATime(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package, runtime: FixtureNeuralSpeechRuntimeOptions(delayMs: 2))
    let first = try await speak(world)
    let second = try await speak(world)
    let endings = [try await ending(first, ms: entry.timeoutMs), try await ending(second, ms: entry.timeoutMs)]
    var observation = Observation(world)
    observation.outcome = endings.first { $0.outcome != "completed" }?.outcome ?? "completed"
    observation.secondOpensAfterFirstStops = world.audio.firstStoppedAtSecondOpen
    return observation
}

private func capabilitiesNeverLoad(_ entry: CatalogCase, _ package: ModelPackage) async throws -> Observation {
    let world = try World(package: package)
    let engine = world.engine
    _ = try await bounded(ms: entry.timeoutMs, "checkCapabilities") { await engine.checkCapabilities() }
    let before = await readiness(world)
    XCTAssertEqual(world.fixtureRuntime.prepareCalls, 0)

    _ = try await bounded(ms: entry.timeoutMs, "prepare") { try await engine.prepare().result() }
    let after = await readiness(world)
    var observation = Observation(world)
    observation.readiness = (before, after)
    return observation
}

// MARK: - Assertions

private func assertCase(_ entry: CatalogCase, _ observed: Observation, sampleRate: Int) {
    let expected = entry.expect
    let id = entry.id
    let world = observed.world
    if let outcome = expected.outcome { XCTAssertEqual(observed.outcome, outcome, id) }
    if let commitCount = expected.commitCount { XCTAssertEqual(observed.commitCount, commitCount, id) }
    if let commitAt = expected.commitAt { XCTAssertEqual(observed.commitAt, commitAt, id) }
    if let sessions = expected.sessions {
        let opened = world.audio.sessions
        XCTAssertEqual(opened.count, sessions.count, id)
        if let first = sessions.first, let session = opened.first {
            if let writes = first.writes { XCTAssertGreaterThanOrEqual(session.writes.count, writes, id) }
            if let stopped = first.stopped { XCTAssertEqual(session.stopped, stopped, id) }
            if first.discardedFrames == "some" { XCTAssertGreaterThan(session.discardedFrames, 0, id) }
            if first.discardedFrames == "none" { XCTAssertEqual(session.discardedFrames, 0, id) }
            if first.playedFrames == "all" {
                XCTAssertGreaterThan(session.writtenFrames, 0, id)
                XCTAssertEqual(session.playedFrames, session.writtenFrames, id)
            }
        } else if sessions.first != nil {
            XCTFail("\(id): no session was opened")
        }
    }
    if let fallbackAsked = expected.fallbackAsked { XCTAssertEqual(observed.fallbackAsked, fallbackAsked, id) }
    if let error = expected.error {
        XCTAssertEqual(observed.error?.errorClass, error.errorClass, id)
        XCTAssertEqual(observed.error?.code, error.code, id)
    }
    if let timing = expected.timing { assertTiming(timing, observed.timing, frames: world.runtime.frames, sampleRate: sampleRate, id) }
    if let artifact = expected.artifact { assertArtifact(artifact, observed.artifact, frames: world.runtime.frames, id) }
    if let runtime = expected.runtime {
        let fixture = world.fixtureRuntime
        if let calls = runtime.synthesizeCalls { XCTAssertEqual(fixture.synthesized.count, calls, id) }
        if let atMost = runtime.synthesizeCallsAtMost { XCTAssertLessThanOrEqual(fixture.synthesized.count, atMost, id) }
        if let prepareCalls = runtime.prepareCalls { XCTAssertEqual(fixture.prepareCalls, prepareCalls, id) }
    }
    if let order = expected.order {
        XCTAssertEqual(observed.secondOpensAfterFirstStops, order.secondOpensAfterFirstStops, id)
    }
    if let readiness = expected.readiness {
        XCTAssertEqual(observed.readiness?.before, readiness.before, id)
        XCTAssertEqual(observed.readiness?.after, readiness.after, id)
        XCTAssertNotNil(observed.readiness, id)
    }
}

private func assertTiming(_ expected: Expectations.Timing, _ timing: PlaybackTiming?, frames: Int, sampleRate: Int, _ id: String) {
    if expected.durationMsEquals == "synthesized" {
        XCTAssertGreaterThan(frames, 0, id)
        XCTAssertEqual(timing?.durationMs ?? -1, Double(frames) / Double(sampleRate) * 1000, accuracy: 1e-6, id)
    }
    if let defined = expected.firstChunkDefined { XCTAssertEqual(timing?.firstChunkMs != nil, defined, id) }
    if let defined = expected.firstAudioDefined { XCTAssertEqual(timing?.firstAudioMs != nil, defined, id) }
}

private func assertArtifact(_ expected: Expectations.Artifact, _ artifact: (mediaType: String, bytes: Data)?, frames: Int, _ id: String) {
    guard let artifact else {
        XCTFail("\(id): no artifact")
        return
    }
    XCTAssertEqual(artifact.mediaType, expected.mediaType, id)
    if expected.byteLengthEquals == "wav" { XCTAssertEqual(artifact.bytes.count, 44 + 2 * frames, id) }
    if let header = expected.header {
        let bytes = [UInt8](artifact.bytes)
        guard bytes.count >= 44 else {
            XCTFail("\(id): the artifact is shorter than a WAV header")
            return
        }
        XCTAssertEqual(Int(uint32(bytes, at: 24)), header.sampleRate, id)
        XCTAssertEqual(Int(uint16(bytes, at: 22)), header.channels, id)
        XCTAssertEqual(Int(uint16(bytes, at: 34)), header.bitsPerSample, id)
        XCTAssertEqual(header.dataBytes, "2*frames", id)
        XCTAssertEqual(Int(uint32(bytes, at: 40)), 2 * frames, id)
    }
}

private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
}

// MARK: - Waiting

private struct WaitExceeded: Error, CustomStringConvertible {
    let label: String
    let ms: Int
    var description: String { "\(label) did not happen within \(ms) ms" }
}

private func bounded<T: Sendable>(ms: Int, _ label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw WaitExceeded(label: label, ms: ms)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw WaitExceeded(label: label, ms: ms) }
        return first
    }
}

private func waitUntil(ms: Int, _ label: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while !condition() {
        if Date() > deadline { throw WaitExceeded(label: label, ms: ms) }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
