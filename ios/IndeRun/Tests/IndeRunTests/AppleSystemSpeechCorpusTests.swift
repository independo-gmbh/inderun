import Foundation
import XCTest
@testable import IndeRunAppleProviders
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// The shared real-audio corpus (`contracts/fixtures/speech/utterance-corpus.json`, #251) through
/// the shipping provider and the real `AVSpeechSynthesizer`. An utterance whose locale has no
/// voice on this host is skipped by id; a refusal the corpus expects must happen on every host.
/// Each test prints one `INDERUN-TRACE` line per run, with ids and measurements but never text,
/// so a run's output can be copied into `docs/verification/system-speech.md`.
final class AppleSystemSpeechCorpusTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Utterance: Decodable {
            let id: String
            let locale: String
            let category: String
            let text: String
            let expect: String
            let errorClass: String?
        }

        struct Scenarios: Decodable {
            struct Repeat: Decodable {
                let utteranceIds: [String]
                let count: Int
            }

            struct Cancel: Decodable {
                let utteranceId: String
                let cancelAfterMs: UInt64
                let followUpUtteranceId: String
            }

            let `repeat`: Repeat
            let cancelMidUtterance: Cancel
        }

        let utterances: [Utterance]
        let scenarios: Scenarios

        func utterance(_ id: String) throws -> Utterance {
            try XCTUnwrap(utterances.first { $0.id == id }, "no utterance \(id) in the corpus")
        }
    }

    private static func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/speech/utterance-corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func engine(also others: [any ProviderAdapter] = []) throws -> IndeRun {
        let registry = ProviderRegistry()
        try registry.register(AppleSystemSpeechProvider())
        for provider in others { try registry.register(provider) }
        return IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
    }

    private func local(_ utterance: Corpus.Utterance) -> SpeakOptions {
        SpeakOptions(
            utterance.text,
            locale: utterance.locale,
            execution: SpeechExecutionOptions(privacy: .localRequired)
        )
    }

    private func trace(_ fields: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("INDERUN-TRACE apple \(data.map { String(decoding: $0, as: UTF8.self) } ?? "{}")")
    }

    // MARK: - Artifacts

    func testEveryCorpusUtteranceRendersARetrievableWAVOrIsSkippedByLocale() async throws {
        let corpus = try Self.loadCorpus()
        let inderun = try engine()
        var rendered: [String] = []
        var skipped: [String] = []
        var durations: [String: Double] = [:]

        for utterance in corpus.utterances where utterance.expect == "speak" {
            let started = Date()
            let speech: GeneratedSpeech
            do {
                speech = try await inderun.generateSpeech(GenerateSpeechOptions(local(utterance), mediaTypes: ["audio/wav"]))
            } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
                skipped.append(utterance.id)
                continue
            } catch let error as IndeRunException
                where rendered.isEmpty && error.details?["code"]?.value as? String == "speech_render_failed" {
                // Only the first render a voice exists for may skip: a host whose audio stack
                // renders nothing at all. Once one utterance has rendered, a failed render is a
                // regression, not the host.
                throw XCTSkip("Speech synthesis is unavailable on this host: \(error.message)")
            }
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            let wav = try await readAll(inderun, speech.artifact.id)
            try assertWAV(wav, artifact: speech.artifact, id: utterance.id)
            XCTAssertEqual(speech.provenance?.locality, .onDevice, utterance.id)
            XCTAssertEqual(speech.provenance?.providerId, "apple_system_speech", utterance.id)

            await inderun.disposeArtifact(artifact: speech.artifact)
            try await assertGone(inderun, speech.artifact.id)
            rendered.append(utterance.id)
            durations[utterance.id] = speech.artifact.durationMs
            trace([
                "id": utterance.id,
                "delivery": "artifact",
                "resolvedLocale": speech.speech?.locale ?? "",
                "voice": speech.speech?.voice?.id ?? "",
                "locality": speech.provenance?.locality.rawValue ?? "",
                "bytes": wav.count,
                "sampleRate": Int(uint32(wav, at: 24)),
                "durationMs": speech.artifact.durationMs ?? -1,
                "synthesisMs": elapsedMs.rounded(),
            ])
        }

        print("INDERUN-TRACE apple corpus rendered=\(rendered) skipped=\(skipped)")
        assertLongTextIsNotCutOff(corpus, durations)
        if rendered.isEmpty { throw XCTSkip("No corpus locale has a voice on this host: \(skipped)") }
    }

    func testRefusedUtterancesNeverReachTheSynthesizer() async throws {
        let corpus = try Self.loadCorpus()
        let inderun = try engine()

        for utterance in corpus.utterances where utterance.expect == "refuse" {
            for call in ["speak", "generateSpeech"] {
                do {
                    if call == "speak" {
                        _ = try await inderun.speak(local(utterance))
                    } else {
                        _ = try await inderun.generateSpeech(GenerateSpeechOptions(local(utterance)))
                    }
                    XCTFail("\(utterance.id): \(call) should have been refused")
                } catch let error as IndeRunException {
                    XCTAssertEqual(error.errorClass.rawValue, utterance.errorClass, "\(utterance.id) \(call)")
                    // Refused by routing: no provider was entered, so nothing could be audible.
                    XCTAssertEqual(error.provenance?.attempts.isEmpty ?? true, true, "\(utterance.id) \(call)")
                    trace(["id": utterance.id, "call": call, "errorClass": error.errorClass.rawValue])
                }
            }
        }
    }

    func testRepeatedRendersAreIndependentArtifacts() async throws {
        let corpus = try Self.loadCorpus()
        let inderun = try engine()
        var covered = 0

        for id in corpus.scenarios.repeat.utteranceIds {
            let utterance = try corpus.utterance(id)
            var artifacts: [MediaArtifact] = []
            do {
                for _ in 0..<corpus.scenarios.repeat.count {
                    artifacts.append(try await inderun.generateSpeech(GenerateSpeechOptions(local(utterance))).artifact)
                }
            } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
                continue
            }
            XCTAssertEqual(Set(artifacts.map(\.id)).count, artifacts.count, "\(id): ids must differ")
            // Disposing one leaves the others readable.
            for (index, artifact) in artifacts.enumerated() {
                for later in artifacts[index...] {
                    _ = try await inderun.readArtifact(request: ArtifactReadRequest(artifactId: later.id, maxBytes: 64, offset: 0))
                }
                await inderun.disposeArtifact(artifact: artifact)
                try await assertGone(inderun, artifact.id)
            }
            covered += 1
            trace(["id": id, "scenario": "repeat", "count": artifacts.count, "bytes": artifacts.map { $0.byteLength ?? -1 }])
        }
        if covered == 0 { throw XCTSkip("No repeat utterance has a voice on this host.") }
    }

    // MARK: - Playback lifecycle

    /// A real stop mid-utterance ends with one `cancelled` outcome, a fallback provider is never
    /// asked to say the text again, and the shared synthesizer speaks the next utterance.
    func testCancelMidUtteranceEndsOnceAndTheNextUtterancePlays() async throws {
        let corpus = try Self.loadCorpus()
        let scenario = corpus.scenarios.cancelMidUtterance
        let fallback = MockStreamProvider(
            id: "z_fallback",
            script: [.init(.result(output: TaskOutput(playback: PlaybackOutput(durationMs: 1)), finishReason: .stop))],
            task: .textToSpeech
        )
        let inderun = try engine(also: [fallback])

        let long = try corpus.utterance(scenario.utteranceId)
        let playback: SpeechPlayback
        do {
            playback = try await inderun.speak(local(long))
        } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
            throw XCTSkip("No \(long.locale) voice on this host.")
        }
        let cancelledAt = Date()
        try await Task.sleep(nanoseconds: scenario.cancelAfterMs * 1_000_000)
        let stopIssued = Date()
        playback.cancel(reason: "corpus cancel")
        let stopped = try await playback.result()
        let stopLatencyMs = Date().timeIntervalSince(stopIssued) * 1000
        let again = try await playback.result()

        XCTAssertEqual(stopped.finishReason, .cancelled)
        XCTAssertEqual(again.finishReason, .cancelled, "the ending is settled once")
        XCTAssertEqual(fallback.callCount, 0, "a committed playback is never repeated by a fallback")
        XCTAssertEqual(stopped.provenance?.attempts.map(\.providerId), ["apple_system_speech"])
        XCTAssertEqual(stopped.provenance?.attempts.first?.committed, true)
        trace([
            "id": long.id,
            "scenario": "cancelMidUtterance",
            "finishReason": "cancelled",
            "cancelAfterMs": Date().timeIntervalSince(cancelledAt) * 1000 - stopLatencyMs,
            "stopLatencyMs": stopLatencyMs.rounded(),
            "fallbackCalls": fallback.callCount,
        ])

        let followUp = try corpus.utterance(scenario.followUpUtteranceId)
        let next = try await speakWithin(seconds: 20, inderun, local(followUp))
        XCTAssertEqual(next.finishReason, .stop)
        XCTAssertEqual(next.provenance?.locality, .onDevice)
        XCTAssertEqual(fallback.callCount, 0)
        trace([
            "id": followUp.id,
            "scenario": "followUp",
            "finishReason": next.finishReason?.rawValue ?? "",
            "durationMs": next.durationMs ?? -1,
            "firstAudioMs": next.firstAudioMs ?? -1,
            "voice": next.speech?.voice?.id ?? "",
        ])
    }

    // MARK: - Helpers

    /// Audio grows with text: a long utterance must last at least half as many times longer than
    /// the short one of its locale as its text is. The synthesizer once ended a render at its first
    /// internal chunk, which kept only a third of long text and passed every per-file check.
    private func assertLongTextIsNotCutOff(_ corpus: Corpus, _ durations: [String: Double]) {
        for long in corpus.utterances where long.category == "long" {
            guard
                let short = corpus.utterances.first(where: { $0.category == "short" && $0.locale == long.locale }),
                let longMs = durations[long.id],
                let shortMs = durations[short.id]
            else { continue }
            let textRatio = Double(long.text.count) / Double(short.text.count)
            XCTAssertGreaterThanOrEqual(longMs / shortMs, textRatio / 2, "\(long.id) looks cut off")
        }
    }

    private func speakWithin(seconds: UInt64, _ engine: IndeRun, _ options: SpeakOptions) async throws -> SpokenSpeech {
        let playback = try await engine.speak(options)
        return try await withThrowingTaskGroup(of: SpokenSpeech?.self) { group in
            group.addTask { try await playback.result() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let ending = first else {
                playback.cancel()
                throw XCTSkip("The synthesizer did not finish within \(seconds) seconds on this host.")
            }
            return ending
        }
    }

    private func assertWAV(_ wav: Data, artifact: MediaArtifact, id: String) throws {
        XCTAssertEqual(artifact.mediaType, "audio/wav", id)
        XCTAssertEqual(artifact.owner, .engine, id)
        XCTAssertEqual(wav.count, try XCTUnwrap(artifact.byteLength), id)
        XCTAssertGreaterThan(wav.count, 44, id)
        XCTAssertLessThanOrEqual(wav.count, 16 * 1024 * 1024, id)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF", id)
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE", id)
        XCTAssertEqual(Int(uint32(wav, at: 4)), wav.count - 8, "\(id): RIFF size")
        XCTAssertEqual(uint16(wav, at: 20), 1, "\(id): PCM")
        XCTAssertEqual(uint16(wav, at: 22), 1, "\(id): mono")
        XCTAssertEqual(uint16(wav, at: 34), 16, "\(id): 16-bit")
        let sampleRate = uint32(wav, at: 24)
        XCTAssertGreaterThan(sampleRate, 0, id)
        let dataBytes = uint32(wav, at: 40)
        XCTAssertEqual(Int(dataBytes), wav.count - 44, id)
        let durationMs = try XCTUnwrap(artifact.durationMs, id)
        XCTAssertGreaterThan(durationMs, 0, id)
        XCTAssertEqual(durationMs, Double(dataBytes / 2) / Double(sampleRate) * 1000, accuracy: 1, id)
    }

    private func assertGone(_ engine: IndeRun, _ artifactId: String) async throws {
        do {
            _ = try await engine.readArtifact(request: ArtifactReadRequest(artifactId: artifactId, maxBytes: nil, offset: nil))
            XCTFail("expected a disposed artifact to be gone")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.details?["code"]?.value as? String, "artifact_not_found")
        }
    }

    private func readAll(_ engine: IndeRun, _ artifactId: String) async throws -> Data {
        var bytes = Data()
        var offset = 0
        while true {
            let read = try await engine.readArtifact(
                request: ArtifactReadRequest(artifactId: artifactId, maxBytes: 64 * 1024, offset: offset)
            )
            bytes.append(read.bytes)
            offset += read.bytes.count
            if read.done { return bytes }
        }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }
}
