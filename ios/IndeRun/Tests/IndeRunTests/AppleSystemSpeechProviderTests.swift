import AVFoundation
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
    private var recordedSpeakControls: [AppleSpeechControls] = []
    private var recordedRenderControls: [AppleSpeechControls] = []
    private var held: [String: CheckedContinuation<Void, Error>] = [:]
    private var heldTexts: Set<String> = []
    private var failures: [String: Error] = [:]
    private var rendered = 0
    private var resolveDelay: TimeInterval = 0
    private var reportedFirstAudioMs: Double? = 120

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
    var speakControls: [AppleSpeechControls] { lock.withLock { recordedSpeakControls } }
    var renderControls: [AppleSpeechControls] { lock.withLock { recordedRenderControls } }
    var renderCount: Int { lock.withLock { rendered } }

    /// Voice lookup is synchronous and happens before the handoff, so blocking here is time the
    /// request spends inside the provider before the runtime is asked to speak.
    func delayVoiceLookup(by seconds: TimeInterval) { lock.withLock { resolveDelay = seconds } }
    func reportFirstAudio(_ ms: Double?) { lock.withLock { reportedFirstAudioMs = ms } }
    func hold(_ text: String) { lock.withLock { _ = heldTexts.insert(text) } }
    func fail(_ text: String, with error: Error) { lock.withLock { failures[text] = error } }
    func remove() { lock.withLock { installed = [] } }

    func release(_ text: String) {
        lock.withLock { held.removeValue(forKey: text) }?.resume()
    }

    func voices() -> [AppleSpeechVoice] {
        let delay = lock.withLock { resolveDelay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return lock.withLock { installed }
    }

    func voice(identifier: String) -> AppleSpeechVoice? {
        voices().first { $0.identifier == identifier }
    }

    func defaultVoice(locale: String?) -> AppleSpeechVoice? { voices().first }

    func warm(voice: AppleSpeechVoice) async throws {
        lock.withLock { recordedWarmed.append(voice.identifier) }
    }

    func speak(text: String, voice: AppleSpeechVoice, controls: AppleSpeechControls) async throws -> SpokenAudio {
        let (holds, failure) = lock.withLock {
            recordedSpoken.append(text)
            recordedSpeakControls.append(controls)
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
        return SpokenAudio(durationMs: 900, firstAudioMs: lock.withLock { reportedFirstAudioMs })
    }

    func render(
        text: String,
        voice: AppleSpeechVoice,
        controls: AppleSpeechControls,
        maxBytes: Int
    ) async throws -> RenderedSpeech {
        lock.withLock {
            rendered += 1
            recordedRenderControls.append(controls)
        }
        return RenderedSpeech(samples: Data(repeating: 1, count: 2200), sampleRate: 22_000)
    }
}

/// A second target that records whether the engine fell back to it.
private func fallbackProvider() -> MockStreamProvider {
    MockStreamProvider(
        id: "z_fallback",
        script: [.init(.result(output: TaskOutput(playback: PlaybackOutput(timing: PlaybackTiming(durationMs: 1, firstAudioMs: nil, firstChunkMs: nil))), finishReason: .stop))],
        task: .textToSpeech
    )
}

final class AppleSystemSpeechProviderTests: XCTestCase {
    func testFirstAudioCountsFromTheRequestNotTheHandoff() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.delayVoiceLookup(by: 0.06)
        let ending = try await engine(runtime).speak(SpeakOptions("Hallo", locale: "de-AT")).result()
        XCTAssertGreaterThanOrEqual(ending.timing?.firstAudioMs ?? 0, 180)
    }

    func testFirstAudioAbsentWhenTheRuntimeReportsNone() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.reportFirstAudio(nil)
        runtime.delayVoiceLookup(by: 0.06)
        let ending = try await engine(runtime).speak(SpeakOptions("Hallo", locale: "de-AT")).result()
        XCTAssertNil(ending.timing?.firstAudioMs)
        XCTAssertEqual(ending.timing?.durationMs, 900)
    }

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
        XCTAssertEqual(ending.timing?.durationMs, 900)
        XCTAssertGreaterThanOrEqual(ending.timing?.firstAudioMs ?? 0, 120)
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

        let speech = try await inderun.generateSpeech(GenerateSpeechOptions(hallo.speech, mediaTypes: ["audio/wav"]))
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
            _ = try await inderun.generateSpeech(GenerateSpeechOptions(hallo.speech, mediaTypes: ["audio/mpeg"]))
            XCTFail("expected a routing refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
        }
        XCTAssertEqual(runtime.renderCount, 0)
    }

    // MARK: - Controls (ADR 025)

    private func number(_ value: Double) -> RequestedNumber {
        RequestedNumber(requirement: nil, value: value)
    }

    func testDeclaresRateAndPitchForBothDeliveriesAndVolumeForPlayback() throws {
        let task = try XCTUnwrap(AppleSystemSpeechProvider(runtime: ScriptedSpeechRuntime()).describe().taskCapabilities?.first)
        let controls = try XCTUnwrap(task.controls)

        XCTAssertEqual(controls.map(\.id), [.speechSpeakingRate, .speechPitch, .playbackVolume])
        XCTAssertEqual(controls.map(\.deliveries), [[.playback, .artifact], [.playback, .artifact], [.playback]])
        XCTAssertEqual(controls.map(\.phase), [.synthesis, .synthesis, .playback])
        XCTAssertTrue(controls.allSatisfy { $0.lifetime == .utterance && $0.valueKind == .number })
    }

    func testReportsTaskLevelControlStates() async throws {
        let provider = AppleSystemSpeechProvider(runtime: ScriptedSpeechRuntime())
        let dynamic = await provider.capabilities(host: HostServices(connectivity: MockConnectivityService(), clock: MockClockService()))
        let states = try XCTUnwrap(dynamic.taskCapabilities?.first?.controlStates)

        func state(_ id: SpeechControlId, _ delivery: ControlDelivery) -> SpeechControlState? {
            states.first { $0.id == id && $0.delivery == delivery }
        }
        XCTAssertEqual(states.count, 5)
        XCTAssertNil(state(.playbackVolume, .artifact))
        for (id, delivery) in [(SpeechControlId.speechSpeakingRate, ControlDelivery.playback), (.speechSpeakingRate, .artifact),
                               (.speechPitch, .playback), (.speechPitch, .artifact)] {
            let range = try XCTUnwrap(state(id, delivery)?.range)
            XCTAssertEqual(state(id, delivery)?.available, true)
            XCTAssertEqual([range.min, range.max, range.speechControlRangeDefault, range.step], [0.5, 2, 1, 0.05])
        }
        let volume = try XCTUnwrap(state(.playbackVolume, .playback)?.range)
        XCTAssertEqual(state(.playbackVolume, .playback)?.available, true)
        XCTAssertEqual([volume.min, volume.max, volume.speechControlRangeDefault, volume.step], [0, 1, 1, 0.05])
    }

    func testRateRangeStaysInsideThePlatformRateRangeWithoutClamping() {
        let minimum = AVSpeechUtteranceMinimumSpeechRate
        let maximum = AVSpeechUtteranceMaximumSpeechRate
        for factor in [0.5, 2.0] {
            let rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * factor)
            XCTAssertTrue((minimum...maximum).contains(rate), "factor \(factor) -> \(rate)")
        }
    }

    func testPlaybackPassesAppliedRatePitchAndVolumeAndRecordsThem() async throws {
        let runtime = ScriptedSpeechRuntime()
        let ending = try await engine(runtime).speak(SpeakOptions(
            "Hallo",
            locale: "de-AT",
            controls: SharedSynthesisControls(pitch: number(1.25), speakingRate: number(0.75)),
            playback: PlaybackControls(volume: RequestedUnitNumber(requirement: nil, value: 0.5))
        )).result()

        XCTAssertEqual(runtime.speakControls, [AppleSpeechControls(rate: 0.75, pitch: 1.25, volume: 0.5)])
        let records = try XCTUnwrap(ending.speech?.controls)
        XCTAssertEqual(records.map(\.id), [.speechSpeakingRate, .speechPitch, .playbackVolume])
        XCTAssertEqual(records.map(\.status), [.applied, .applied, .applied])
        XCTAssertEqual(records.map(\.requested), [0.75, 1.25, 0.5])
        XCTAssertEqual(records.map(\.effective), [0.75, 1.25, 0.5])
        XCTAssertEqual(records.map(\.method), [.platformSynthesis, .platformSynthesis, .playbackAttenuation])
    }

    func testAnOmittedControlStaysUnsetAndIsRecordedNotApplied() async throws {
        let runtime = ScriptedSpeechRuntime()
        let ending = try await engine(runtime).speak(SpeakOptions(
            "Hallo",
            locale: "de-AT",
            controls: SharedSynthesisControls(pitch: nil, speakingRate: number(3))
        )).result()

        XCTAssertEqual(runtime.speakControls, [AppleSpeechControls()])
        let record = try XCTUnwrap(ending.speech?.controls?.first)
        XCTAssertEqual(record.status, .notApplied)
        XCTAssertEqual(record.reason, .outOfRange)
        XCTAssertEqual(record.requested, 3)
        XCTAssertNil(record.effective)
    }

    func testRenderPassesRateAndPitchAndNeverVolume() async throws {
        let runtime = ScriptedSpeechRuntime()
        let speech = try await engine(runtime).generateSpeech(GenerateSpeechOptions(
            SpeechOptions(
                "Hallo",
                locale: "de-AT",
                controls: SharedSynthesisControls(pitch: number(0.5), speakingRate: number(2))
            ),
            mediaTypes: ["audio/wav"]
        ))

        XCTAssertEqual(runtime.renderControls, [AppleSpeechControls(rate: 2, pitch: 0.5, volume: nil)])
        let records = try XCTUnwrap(speech.speech?.controls)
        XCTAssertEqual(records.map(\.method), [.platformSynthesis, .platformSynthesis])
        XCTAssertEqual(records.map(\.effective), [2, 0.5])
    }

    func testARunWithoutControlsIsUnchanged() async throws {
        let runtime = ScriptedSpeechRuntime()
        let ending = try await engine(runtime).speak(hallo).result()

        XCTAssertEqual(runtime.speakControls, [AppleSpeechControls()])
        XCTAssertNil(ending.speech?.controls)
        XCTAssertEqual(ending.finishReason, .stop)
    }

    func testCancellationWithControlsStillEndsCancelled() async throws {
        let runtime = ScriptedSpeechRuntime()
        runtime.hold("Hallo")
        let run = try await engine(runtime).stream(request: SpeakOptions(
            "Hallo",
            locale: "de-AT",
            controls: SharedSynthesisControls(pitch: nil, speakingRate: number(1.5))
        ).taskRequest())
        try await waitUntil { !runtime.spoken.isEmpty }
        run.cancel(reason: "stop")
        var terminals: [Outcome?] = []
        for try await event in run.events where event.type == "terminal" {
            terminals.append(event.payload?.outcome)
        }

        XCTAssertEqual(terminals, [.cancelled])
        XCTAssertEqual(runtime.stopped, ["Hallo"])
    }
}
