import Foundation
import XCTest
@testable import IndeRunAppleProviders
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// A scripted synthesizer: playback finishes at once, or holds until the test releases or
/// cancels it, so every lifecycle ordering is deterministic.
private final class ScriptedSpeechRuntime: AppleSpeechRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: [AppleSpeechVoice]
    private var recordedSpoken: [String] = []
    private var recordedVoices: [String] = []
    private var recordedWarmed: [String] = []
    private var recordedStopped: [String] = []
    private var held: [String: CheckedContinuation<Void, Error>] = [:]
    private var heldTexts: Set<String> = []
    private var failures: [String: Error] = [:]
    private var rendered = 0

    init(voices: [AppleSpeechVoice] = ScriptedSpeechRuntime.german) {
        installed = voices
    }

    static let german = [
        AppleSpeechVoice(identifier: "anna", locale: "de-DE", gender: .female),
        AppleSpeechVoice(identifier: "anna2", locale: "de-DE", gender: .female),
        AppleSpeechVoice(identifier: "markus", locale: "de-DE", gender: .male)
    ]

    var spoken: [String] { lock.withLock { recordedSpoken } }
    var spokenVoices: [String] { lock.withLock { recordedVoices } }
    var warmedVoices: [String] { lock.withLock { recordedWarmed } }
    var stopped: [String] { lock.withLock { recordedStopped } }
    var renderCount: Int { lock.withLock { rendered } }

    func hold(_ text: String) { lock.withLock { _ = heldTexts.insert(text) } }
    func fail(_ text: String, with error: Error) { lock.withLock { failures[text] = error } }
    func remove() { lock.withLock { installed = [] } }

    func release(_ text: String) {
        lock.withLock { held.removeValue(forKey: text) }?.resume()
    }

    func voices() -> [AppleSpeechVoice] { lock.withLock { installed } }

    func voice(identifier: String) -> AppleSpeechVoice? {
        voices().first { $0.identifier == identifier }
    }

    func defaultVoice(locale: String?) -> AppleSpeechVoice? { voices().first }

    func warm(voice: AppleSpeechVoice) async throws {
        lock.withLock { recordedWarmed.append(voice.identifier) }
    }

    func speak(text: String, voice: AppleSpeechVoice) async throws -> SpokenAudio {
        let (holds, failure) = lock.withLock {
            recordedSpoken.append(text)
            recordedVoices.append(voice.identifier)
            return (heldTexts.contains(text), failures[text])
        }
        if let failure { throw failure }
        if holds {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let cancelled = lock.withLock {
                            if !Task.isCancelled { held[text] = continuation }
                            return Task.isCancelled
                        }
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                    }
                } onCancel: {
                    lock.withLock { held.removeValue(forKey: text) }?.resume(throwing: CancellationError())
                }
            } catch {
                lock.withLock { recordedStopped.append(text) }
                throw error
            }
        }
        return SpokenAudio(durationMs: 900, firstAudioMs: 120)
    }

    func render(text: String, voice: AppleSpeechVoice, maxBytes: Int) async throws -> RenderedSpeech {
        lock.withLock { rendered += 1 }
        return RenderedSpeech(samples: Data(repeating: 1, count: 2200), sampleRate: 22_000)
    }
}

/// A second target that records whether the engine fell back to it.
private func fallbackProvider() -> MockStreamProvider {
    MockStreamProvider(
        id: "z_fallback",
        script: [.init(.result(output: TaskOutput(playback: PlaybackOutput(durationMs: 1)), finishReason: .stop))],
        task: .textToSpeech
    )
}

final class AppleSystemSpeechProviderTests: XCTestCase {
    private func engine(
        _ runtime: ScriptedSpeechRuntime,
        also others: [any ProviderAdapter] = [],
        online: Bool = true
    ) throws -> IndeRun {
        let registry = ProviderRegistry()
        try registry.register(AppleSystemSpeechProvider(runtime: runtime))
        for provider in others { try registry.register(provider) }
        return IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "condition not reached in time")
    }

    private var hallo: SpeakOptions { SpeakOptions("Hallo", locale: "de-AT") }

    // MARK: - Capabilities

    func testDeclaresPlaybackAndArtifactAndHardCancel() throws {
        let descriptor = AppleSystemSpeechProvider(runtime: ScriptedSpeechRuntime()).describe()
        let task = try XCTUnwrap(descriptor.taskCapabilities?.first)

        XCTAssertEqual(descriptor.id, "apple_system_speech")
        XCTAssertEqual(descriptor.supports.streaming, true)
        XCTAssertEqual(descriptor.privacy?.dataLeavesDevice, false)
        XCTAssertEqual(task.kind, "text_to_speech")
        XCTAssertEqual(task.cancel, .hard)
        XCTAssertEqual(task.interaction.stream, true)
        XCTAssertEqual(task.outputs.map(\.delivery), [.playback, .artifact])
        XCTAssertEqual(task.outputs.last?.mediaTypes, ["audio/wav"])
    }

    func testIsUnavailableWithoutVoices() async throws {
        let inderun = try engine(ScriptedSpeechRuntime(voices: []))

        do {
            _ = try await inderun.speak(hallo)
            XCTFail("expected a routing refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.provenance?.routeRejections.first?.providerId, "apple_system_speech")
        }
    }

    // MARK: - Playback

    func testSpeakCompletesThroughRoutingWithTheVoiceThatSpoke() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)

        let ending = try await inderun.speak(SpeakOptions(
            "Hallo",
            locale: "de-AT",
            voice: SpeechVoice(gender: .male, requirement: .requirementLevelRequired),
            execution: SpeechExecutionOptions(privacy: .localRequired)
        )).result()

        XCTAssertEqual(runtime.spoken, ["Hallo"])
        XCTAssertEqual(ending.finishReason, .stop)
        XCTAssertEqual(ending.durationMs, 900)
        XCTAssertEqual(ending.firstAudioMs, 120)
        XCTAssertEqual(ending.speech?.locale, "de-DE")
        XCTAssertEqual(ending.speech?.voice?.gender, .male)
        XCTAssertEqual(ending.provenance?.providerId, "apple_system_speech")
        XCTAssertEqual(ending.provenance?.locality, .onDevice)
        XCTAssertEqual(ending.provenance?.attempts.first?.committed, true)
    }

    func testPlaybackThroughRunCompletes() async throws {
        let runtime = ScriptedSpeechRuntime()
        let result = try await engine(runtime).run(request: hallo.taskRequest())

        XCTAssertEqual(result.output.type, .playback)
        XCTAssertEqual(result.provenance?.attempts.first?.committed, true)
    }

    func testCancelStopsTheAudioWithOneTerminalOutcome() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.hold("Hallo")
        let inderun = try engine(runtime)

        let run = try await inderun.stream(request: hallo.taskRequest())
        try await waitUntil { runtime.spoken == ["Hallo"] }
        run.cancel(reason: "stop")
        run.cancel(reason: "again")
        var terminals: [Outcome?] = []
        for try await event in run.events where event.type == "terminal" {
            terminals.append(event.payload?.outcome)
        }

        XCTAssertEqual(terminals, [.cancelled])
        XCTAssertEqual(runtime.stopped, ["Hallo"])
    }

    func testAFailureAfterCommitDoesNotFallBack() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.fail("Hallo", with: createUnavailable(message: "audio failed"))
        let fallback = fallbackProvider()
        let inderun = try engine(runtime, also: [fallback])

        // The exact region ranks this provider ahead of the fallback.
        let playback = try await inderun.speak(SpeakOptions("Hallo", locale: "de-DE"))
        do {
            _ = try await playback.result()
            XCTFail("expected the run to fail")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
            XCTAssertEqual(error.provenance?.attempts.count, 1)
        }
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testAVoiceRemovedSincePlanningIsRefusedBeforeCommit() async throws {
        let runtime = ScriptedSpeechRuntime()
        let provider = AppleSystemSpeechProvider(runtime: runtime)
        let context = RunContext(
            runId: "run_1",
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService()),
            voice: ProviderVoice(locale: "de-DE", gender: .female, id: "anna")
        )
        runtime.remove()

        do {
            _ = try await provider.run(request: hallo.taskRequest(), context: context)
            XCTFail("expected a refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
            XCTAssertEqual(error.details?["code"]?.value as? String, "voice_not_available")
        }
        XCTAssertEqual(runtime.spoken, [])
    }

    // MARK: - Choosing a voice

    func testEveryVoiceIsListedWithItsIdAndName() async throws {
        let inderun = try engine(ScriptedSpeechRuntime())

        let voices = await inderun.listVoices()

        XCTAssertEqual(voices.map(\.id), ["anna", "anna2", "markus"])
    }

    func testAPickedVoiceSpeaksAndIsReported() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)
        let picked = await inderun.listVoices()[1]

        var options = hallo
        options.voice = picked.asSpeechVoice()
        let ending = try await inderun.speak(options).result()

        XCTAssertEqual(ending.speech?.voice?.id, "anna2")
        XCTAssertEqual(runtime.spokenVoices, ["anna2"])
    }

    func testPrepareWarmsSilentlyAndThenReportsTheVoiceReady() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)

        let result = try await inderun.prepare().result()

        XCTAssertEqual(runtime.warmedVoices, ["anna"])
        XCTAssertEqual(runtime.spoken, [])
        XCTAssertEqual(result.items.map(\.status), [.prepared])
    }

    func testAColdVoiceIsLeftAloneOnTheFirstCallBecauseSpeakingWarmsIt() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)

        _ = try await inderun.speak(hallo).result()

        XCTAssertEqual(runtime.warmedVoices, [])
        XCTAssertEqual(runtime.spoken, ["Hallo"])
    }

    func testARequiredVoiceThatIsGoneIsRefused() async throws {
        let inderun = try engine(ScriptedSpeechRuntime())

        var options = hallo
        options.voice = SpeechVoice(
            gender: nil,
            id: "gone",
            providerId: AppleSystemSpeechProvider.defaultId,
            requirement: .requirementLevelRequired
        )
        do {
            _ = try await inderun.speak(options)
            XCTFail("expected a refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
        }
    }

    // MARK: - One utterance at a time

    func testUtterancesPlayInOrderAndCommitOnlyAtTheirTurn() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.hold("eins")
        let inderun = try engine(runtime)

        let first = try await inderun.speak(SpeakOptions("eins", locale: "de-DE"))
        try await waitUntil { runtime.spoken == ["eins"] }
        let second = try await inderun.speak(SpeakOptions("zwei", locale: "de-DE"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(runtime.spoken, ["eins"])

        runtime.release("eins")
        _ = try await first.result()
        let ending = try await second.result()

        XCTAssertEqual(runtime.spoken, ["eins", "zwei"])
        XCTAssertEqual(ending.finishReason, .stop)
    }

    func testAVoiceRemovedWhileWaitingIsRefusedBeforeCommitAndFallsBack() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.hold("eins")
        let fallback = fallbackProvider()
        let inderun = try engine(runtime, also: [fallback])

        let first = try await inderun.speak(SpeakOptions("eins", locale: "de-DE"))
        try await waitUntil { runtime.spoken == ["eins"] }
        let second = try await inderun.speak(SpeakOptions("zwei", locale: "de-DE"))
        try await Task.sleep(nanoseconds: 20_000_000)
        runtime.remove()
        runtime.release("eins")
        _ = try await first.result()
        let ending = try await second.result()

        XCTAssertEqual(runtime.spoken, ["eins"])
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(ending.provenance?.attempts.first?.errorClass, .CapabilityMismatch)
        XCTAssertNil(ending.provenance?.attempts.first?.committed)
    }

    func testCancellingAWaitingUtteranceNeverPlaysIt() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.hold("eins")
        let inderun = try engine(runtime)

        let first = try await inderun.speak(SpeakOptions("eins", locale: "de-DE"))
        try await waitUntil { runtime.spoken == ["eins"] }
        let second = try await inderun.speak(SpeakOptions("zwei", locale: "de-DE"))
        try await Task.sleep(nanoseconds: 20_000_000)
        second.cancel()
        let ending = try await second.result()
        runtime.release("eins")
        _ = try await first.result()

        XCTAssertEqual(ending.finishReason, .cancelled)
        XCTAssertNil(ending.provenance?.attempts.first?.committed)
        XCTAssertEqual(runtime.spoken, ["eins"])
    }

    // MARK: - Artifact

    func testGenerateSpeechReturnsAWavArtifactWithoutPlaying() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)

        let speech = try await inderun.generateSpeech(GenerateSpeechOptions(hallo, mediaTypes: ["audio/wav"]))
        let chunk = try await inderun.readArtifact(
            request: ArtifactReadRequest(artifactId: speech.artifact.id, maxBytes: nil, offset: nil)
        )

        XCTAssertEqual(runtime.spoken, [])
        XCTAssertEqual(runtime.renderCount, 1)
        XCTAssertEqual(speech.artifact.mediaType, "audio/wav")
        XCTAssertEqual(speech.artifact.durationMs, 50)
        XCTAssertEqual(speech.speech?.locale, "de-DE")
        XCTAssertEqual(String(decoding: chunk.bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(chunk.totalBytes, 2244)
    }

    func testAnUnsupportedMediaTypeIsRefusedByRouting() async throws {
        let runtime = ScriptedSpeechRuntime()
        let inderun = try engine(runtime)

        do {
            _ = try await inderun.generateSpeech(GenerateSpeechOptions(hallo, mediaTypes: ["audio/mpeg"]))
            XCTFail("expected a routing refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
        }
        XCTAssertEqual(runtime.renderCount, 0)
    }
}
