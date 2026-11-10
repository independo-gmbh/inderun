import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// An `IndeRunApi` that answers `listVoices` from fixed snapshots and `generateSpeech` from a
/// fixed result: the facade is tested against the interface, not an engine.
private struct ScriptedApi: IndeRunApi {
    var snapshots: [ProviderCapabilitySnapshot] = []
    var result: TaskResult?

    func run(request: TaskRequest) async throws -> TaskResult { try XCTUnwrap(result) }

    func prepare(request: PrepareRequest) async throws -> StreamRun { fatalError("not scripted") }

    func stream(request: TaskRequest) async throws -> StreamRun {
        throw createInternal(message: "not scripted")
    }

    func checkCapabilities() async -> [ProviderCapabilitySnapshot] { snapshots }

    func readArtifact(request: ArtifactReadRequest) async throws -> ArtifactChunk {
        throw createInternal(message: "not scripted")
    }

    func disposeArtifact(artifact: MediaArtifact) async {}
    func close() async {}
}

final class SpeechGenerationTests: XCTestCase {
    // MARK: - Shared vectors

    private struct AnyJSON: Decodable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let number = try? container.decode(Int.self) {
                value = number
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let array = try? container.decode([AnyJSON].self) {
                value = array.map(\.value)
            } else {
                value = try container.decode([String: AnyJSON].self).mapValues(\.value)
            }
        }
    }

    private struct FacadeVector: Decodable {
        let id: String
        let call: String
        let options: [String: AnyJSON]
        let expected: AnyJSON
    }

    private struct FacadeFixture: Decodable {
        let cases: [FacadeVector]
    }

    private struct ListVoicesVector: Decodable {
        let id: String
        let snapshots: [ProviderCapabilitySnapshot]
        let options: [String: AnyJSON]?
        let expected: AnyJSON
    }

    private struct ListVoicesFixture: Decodable {
        let cases: [ListVoicesVector]
    }

    private struct LocalityVector: Decodable {
        let id: String
        let providerType: String
        let taskDataLeavesDevice: Bool?
        let voice: ProviderVoice?
        let unverifiedVoice: Bool?
        let expected: String
    }

    private struct LocalityFixture: Decodable {
        let cases: [LocalityVector]
    }

    private func fixtureURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/\(path)")
    }

    private func speakOptions(from raw: [String: Any]) throws -> SpeakOptions {
        let voice = (raw["voice"] as? [String: Any]).map { voice in
            SpeechVoice(
                gender: (voice["gender"] as? String).flatMap(VoiceGender.init(rawValue:)),
                id: voice["id"] as? String,
                providerId: voice["providerId"] as? String,
                requirement: (voice["requirement"] as? String).flatMap(RequirementLevel.init(rawValue:))
            )
        }
        let execution = (raw["execution"] as? [String: Any]).map { execution in
            SpeechExecutionOptions(
                privacy: (execution["privacy"] as? String).flatMap(Privacy.init(rawValue:)),
                cloud: (execution["cloud"] as? String).flatMap(Cloud.init(rawValue:)),
                timeoutMs: execution["timeoutMs"] as? Int,
                optimizeFor: (execution["optimizeFor"] as? String).flatMap(OptimizeFor.init(rawValue:))
            )
        }
        return SpeakOptions(
            try XCTUnwrap(raw["text"] as? String),
            locale: try XCTUnwrap(raw["locale"] as? String),
            localeMatch: (raw["localeMatch"] as? String).flatMap(LocaleMatch.init(rawValue:)),
            voice: voice,
            model: raw["model"] as? String,
            execution: execution,
            authContextRef: raw["authContextRef"] as? String,
            requestId: raw["requestId"] as? String
        )
    }

    func testMatchesTheSharedFacadeVectors() throws {
        let fixture = try JSONDecoder().decode(
            FacadeFixture.self,
            from: Data(contentsOf: fixtureURL("facade/speech.json"))
        )
        XCTAssertFalse(fixture.cases.isEmpty)
        for vector in fixture.cases {
            let raw = vector.options.mapValues(\.value)
            let speak = try speakOptions(from: raw)
            let request = vector.call == "speak"
                ? speak.taskRequest()
                : GenerateSpeechOptions(
                    speak,
                    mediaTypes: raw["mediaTypes"] as? [String],
                    destinationRef: raw["destinationRef"] as? String
                ).taskRequest()
            let encoded = try JSONSerialization.jsonObject(with: try request.jsonData()) as? NSDictionary
            XCTAssertEqual(encoded, vector.expected.value as? NSDictionary, vector.id)
        }
    }

    func testMatchesTheSharedListVoicesVectors() async throws {
        let fixture = try JSONDecoder().decode(
            ListVoicesFixture.self,
            from: Data(contentsOf: fixtureURL("facade/list-voices.json"))
        )
        XCTAssertFalse(fixture.cases.isEmpty)
        for vector in fixture.cases {
            let raw = vector.options?.mapValues(\.value) ?? [:]
            let voices = await ScriptedApi(snapshots: vector.snapshots).listVoices(
                locale: raw["locale"] as? String,
                localeMatch: (raw["localeMatch"] as? String).flatMap(LocaleMatch.init(rawValue:))
            )
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(voices)) as? NSArray
            XCTAssertEqual(encoded, vector.expected.value as? NSArray, vector.id)
        }
    }

    func testMatchesTheSharedVoiceLocalityVectors() throws {
        let fixture = try JSONDecoder().decode(
            LocalityFixture.self,
            from: Data(contentsOf: fixtureURL("execution/voice-locality.json"))
        )
        XCTAssertFalse(fixture.cases.isEmpty)
        for vector in fixture.cases {
            let descriptor = speechDescriptor(
                type: try XCTUnwrap(ProviderType(rawValue: vector.providerType)),
                taskDataLeavesDevice: vector.taskDataLeavesDevice
            )
            let locality = ProvenanceRecorder.locality(
                of: descriptor,
                bound: vector.voice.map { ("text_to_speech", $0) }
                    ?? (vector.unverifiedVoice == true ? ("text_to_speech", nil) : nil)
            )
            XCTAssertEqual(locality.rawValue, vector.expected, vector.id)
        }
    }

    private func speechDescriptor(type: ProviderType, taskDataLeavesDevice: Bool?) -> ProviderDescriptor {
        ProviderDescriptor(
            id: "p",
            type: type,
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
                    outputs: [ProviderTaskOutput(delivery: .playback)],
                    privacy: taskDataLeavesDevice.map { ProviderPrivacy(dataLeavesDevice: $0) }
                )
            ]
        )
    }

    // MARK: - speak

    private func engine(script: [MockStreamProvider.Step]) throws -> IndeRun {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "tts", script: script, task: .textToSpeech))
        return IndeRun(registry: registry, hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService()))
    }

    private var options: SpeakOptions { SpeakOptions("Hallo", locale: "de-AT") }

    func testPlaybackTimingDecodesFromTheWire() throws {
        let output = try JSONDecoder().decode(PlaybackOutput.self, from: Data(#"{"timing":{"firstAudioMs":80}}"#.utf8))
        XCTAssertEqual(output.timing?.firstAudioMs, 80)
        XCTAssertNil(output.timing?.durationMs)
    }

    func testSpeakResolvesWithWhatPlayedAndTheProvenance() async throws {
        let output = TaskOutput(
            playback: PlaybackOutput(timing: PlaybackTiming(durationMs: 1200, firstAudioMs: 150, firstChunkMs: 95)),
            speech: SpeechOutput(locale: "de-DE", voice: nil)
        )
        let inderun = try engine(script: [.commit, .init(.result(output: output, finishReason: .stop, reportedModel: nil))])

        let ending = try await inderun.speak(options).result()

        XCTAssertEqual(ending.finishReason, .stop)
        XCTAssertEqual(ending.timing?.durationMs, 1200)
        XCTAssertEqual(ending.timing?.firstChunkMs, 95)
        XCTAssertEqual(ending.speech?.locale, "de-DE")
        XCTAssertEqual(ending.provenance?.providerId, "tts")
        XCTAssertEqual(ending.provenance?.attempts.first?.committed, true)
    }

    func testCancelledPlaybackKeepsItsTiming() async throws {
        let provenance = ExecutionProvenance(
            attemptCount: 1,
            attempts: [ExecutionProvenanceAttempt(committed: true, errorClass: nil, outcome: .cancelled, providerId: "tts")],
            configuredModel: nil,
            fallbackOccurred: false,
            locality: .onDevice,
            modelProfile: "auto",
            providerId: "tts",
            reportedModel: nil,
            routeRejections: [],
            schemaVersion: .the10
        )
        let outcome = StreamTerminalOutcome(
            finalText: nil,
            finishReason: nil,
            outcome: .cancelled,
            output: TaskOutput(
                playback: PlaybackOutput(timing: PlaybackTiming(durationMs: 640, firstAudioMs: nil, firstChunkMs: nil))
            ),
            provenance: provenance,
            runId: "r2",
            schemaVersion: .the10,
            telemetry: nil,
            usage: nil,
            error: nil,
            partialText: nil,
            reason: nil
        )
        let terminal = StreamEvent(
            payload: Payload(terminalOutcome: outcome),
            runId: "r2",
            schemaVersion: .the10,
            sequence: 0,
            timestamp: 0,
            type: "terminal"
        )
        let run = StreamRun(
            handle: StreamRunHandle(providerId: "tts", runId: "r2", schemaVersion: .the10, startedAt: 0),
            events: AsyncThrowingStream { continuation in
                continuation.yield(terminal)
                continuation.finish()
            },
            cancel: { _ in }
        )

        let ending = try await SpeechPlayback(run: run).result()

        XCTAssertEqual(ending.finishReason, .cancelled)
        XCTAssertEqual(ending.timing?.durationMs, 640)
    }

    func testCancelStopsPlaybackAndResolvesRatherThanThrows() async throws {
        let inderun = try engine(script: [.commit, .waitForCancellation])

        let playback = try await inderun.speak(options)
        // Let the attempt reach its commit, so the cancel stops audio rather than preventing it.
        try await Task.sleep(nanoseconds: 20_000_000)
        playback.cancel(reason: "stop")
        playback.cancel(reason: "again")
        let ending = try await playback.result()

        XCTAssertEqual(ending.finishReason, .cancelled)
        XCTAssertEqual(ending.provenance?.attempts.first?.outcome, .cancelled)
        XCTAssertEqual(ending.provenance?.attempts.first?.committed, true)
    }

    func testAFailedRunThrowsItsExceptionWithProvenance() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(
            id: "tts",
            script: [.commit],
            throwAfterScript: createUnavailable(message: "gone"),
            task: .textToSpeech
        ))
        let inderun = IndeRun(registry: registry, hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService()))

        let playback = try await inderun.speak(options)
        do {
            _ = try await playback.result()
            XCTFail("expected the run to fail")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
            XCTAssertEqual(error.provenance?.providerId, "tts")
        }
    }

    // MARK: - generateSpeech

    func testGenerateSpeechReturnsTheArtifactWithWhatWasUsed() async throws {
        let artifact = MediaArtifact(
            byteLength: 44,
            destinationRef: nil,
            durationMs: nil,
            id: "art_1",
            lifetime: .untilDisposed,
            mediaType: "audio/wav",
            owner: .engine
        )
        let result = TaskResult(
            runId: "run_1",
            output: TaskOutput(artifact: artifact, speech: SpeechOutput(locale: "de-DE", voice: nil)),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: "tts", totalMs: 1)
        )

        let speech = try await ScriptedApi(result: result).generateSpeech(GenerateSpeechOptions(options))

        XCTAssertEqual(speech.artifact.id, "art_1")
        XCTAssertEqual(speech.speech?.locale, "de-DE")
        XCTAssertEqual(speech.finishReason, .stop)
        XCTAssertEqual(speech.runId, "run_1")
    }

    func testGenerateSpeechRefusesAResultWithoutAnArtifact() async {
        let result = TaskResult(
            runId: "run_1",
            output: TaskOutput(text: "not audio"),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: "tts", totalMs: 1)
        )

        do {
            _ = try await ScriptedApi(result: result).generateSpeech(GenerateSpeechOptions(options))
            XCTFail("expected a failure")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Internal)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - listVoices

    private func snapshot(
        _ id: String,
        available: Bool = true,
        taskAvailable: Bool? = nil,
        voices: [ProviderVoice]?
    ) -> ProviderCapabilitySnapshot {
        ProviderCapabilitySnapshot(
            providerId: id,
            descriptor: speechDescriptor(type: .local, taskDataLeavesDevice: nil),
            capabilities: ProviderDynamicCapabilities(
                available: available,
                taskCapabilities: voices.map {
                    [ProviderTaskAvailability(kind: "text_to_speech", available: taskAvailable, voices: $0)]
                }
            )
        )
    }

    private var voiceApi: ScriptedApi {
        ScriptedApi(snapshots: [
            snapshot("text_only", voices: nil),
            snapshot("off", available: false, voices: [ProviderVoice(locale: "de-DE")]),
            snapshot("task_off", taskAvailable: false, voices: [ProviderVoice(locale: "de-DE")]),
            snapshot("tts", voices: [
                ProviderVoice(locale: "de-DE", gender: .female, networkRequired: false, readiness: nil),
                ProviderVoice(locale: "de_AT"),
                ProviderVoice(locale: "en-GB", networkRequired: true)
            ])
        ])
    }

    func testListsTheVoicesOfAvailableProvidersInOrder() async {
        let voices = await voiceApi.listVoices()

        XCTAssertEqual(voices, [
            SpeechVoiceInfo(providerId: "tts", kind: .platform, model: nil, id: nil, name: nil, locale: "de-DE", locales: nil, gender: .female, networkRequired: false, readiness: nil),
            SpeechVoiceInfo(providerId: "tts", kind: .platform, model: nil, id: nil, name: nil, locale: "de_AT", locales: nil, gender: nil, networkRequired: nil, readiness: nil),
            SpeechVoiceInfo(providerId: "tts", kind: .platform, model: nil, id: nil, name: nil, locale: "en-GB", locales: nil, gender: nil, networkRequired: true, readiness: nil)
        ])
    }

    func testACatalogEntryBecomesAScopedRequestVoice() {
        let voice = SpeechVoiceInfo(
            providerId: "tts",
            kind: .platform,
            model: nil,
            id: "anna",
            name: "Anna",
            locale: "de-DE",
            locales: nil,
            gender: .female,
            networkRequired: nil,
            readiness: nil
        ).asSpeechVoice(requirement: .requirementLevelRequired)

        XCTAssertEqual(voice.id, "anna")
        XCTAssertEqual(voice.providerId, "tts")
        XCTAssertEqual(voice.gender, .female)
        XCTAssertEqual(voice.requirement, .requirementLevelRequired)
    }

    func testACatalogEntryWithoutAnIdSelectsByTraits() {
        let voice = SpeechVoiceInfo(
            providerId: "tts",
            kind: .platform,
            model: nil,
            id: nil,
            name: nil,
            locale: "de-DE",
            locales: nil,
            gender: .female,
            networkRequired: nil,
            readiness: nil
        ).asSpeechVoice()

        XCTAssertNil(voice.providerId)
        XCTAssertEqual(voice.gender, .female)
    }

    func testMatchesALocaleByLanguageByDefault() async {
        let voices = await voiceApi.listVoices(locale: "de-AT")

        XCTAssertEqual(voices.map(\.locale), ["de-DE", "de_AT"])
    }

    func testMatchesTheWholeTagWhenAskedTo() async {
        let voices = await voiceApi.listVoices(locale: "DE-de", localeMatch: .exact)

        XCTAssertEqual(voices.map(\.locale), ["de-DE"])
    }
}
