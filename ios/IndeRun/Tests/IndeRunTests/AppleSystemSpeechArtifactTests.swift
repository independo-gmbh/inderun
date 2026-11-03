import Foundation
import XCTest
@testable import IndeRunAppleProviders
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// Real retrievable audio through the shipping provider: `AVSpeechSynthesizer.write` renders
/// actual speech, and the test reads the WAV artifact back through `readArtifact`. It skips only
/// when the host cannot synthesize at all; anything else is a real failure of the artifact path.
final class AppleSystemSpeechArtifactTests: XCTestCase {
    func testSynthesizedSpeechIsARetrievableWAVArtifact() async throws {
        let registry = ProviderRegistry()
        try registry.register(AppleSystemSpeechProvider())
        let engine = IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
        let request = TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            speech: SpeechInput(locale: "en-US", localeMatch: .language, text: "Your appointment is at 3 pm.", voice: nil),
            delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: ["audio/wav"], mode: .artifact)
        )

        let result: TaskResult
        do {
            result = try await engine.run(request: request)
        } catch let error as IndeRunException
            where error.errorClass == .CapabilityMismatch
            || error.details?["code"]?.value as? String == "speech_render_failed" {
            throw XCTSkip("Speech synthesis is unavailable on this host: \(error.message)")
        }

        let artifact = try XCTUnwrap(result.output.artifact)
        XCTAssertEqual(artifact.mediaType, "audio/wav")
        XCTAssertEqual(artifact.owner, .engine)
        let byteLength = try XCTUnwrap(artifact.byteLength)
        XCTAssertGreaterThan(byteLength, 44)
        XCTAssertGreaterThan(try XCTUnwrap(artifact.durationMs), 0)

        // Read in ranges, then compare with a second full pass: reads do not consume the artifact.
        let wav = try await readAll(engine, artifact.id, chunk: 4096)
        XCTAssertEqual(wav.count, byteLength)
        let secondPass = try await readAll(engine, artifact.id, chunk: 1 << 20)
        XCTAssertEqual(secondPass, wav)

        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(uint16(wav, at: 20), 1, "PCM")
        XCTAssertEqual(uint16(wav, at: 22), 1, "mono")
        XCTAssertEqual(uint16(wav, at: 34), 16, "16-bit")
        let sampleRate = uint32(wav, at: 24)
        XCTAssertGreaterThan(sampleRate, 0)
        let dataBytes = uint32(wav, at: 40)
        XCTAssertEqual(Int(dataBytes), wav.count - 44)
        XCTAssertEqual(
            try XCTUnwrap(artifact.durationMs),
            Double(dataBytes / 2) / Double(sampleRate) * 1000,
            accuracy: 1
        )

        await engine.disposeArtifact(artifact: artifact)
        do {
            _ = try await engine.readArtifact(request: ArtifactReadRequest(artifactId: artifact.id, maxBytes: nil, offset: nil))
            XCTFail("expected a disposed artifact to be gone")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.details?["code"]?.value as? String, "artifact_not_found")
        }
    }

    /// The real synthesizer's lifecycle: an utterance finishes, and a later one stops on cancel.
    /// Skips when the host never starts speaking, as a runner without an audio stack may not.
    func testRealPlaybackFinishesAndStopsOnCancel() async throws {
        let registry = ProviderRegistry()
        try registry.register(AppleSystemSpeechProvider())
        let engine = IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )

        let finished = try await speakWithin(seconds: 15, engine, SpeakOptions("Hello.", locale: "en-US"))
        XCTAssertEqual(finished.finishReason, .stop)
        XCTAssertEqual(finished.provenance?.attempts.first?.committed, true)

        let long = String(repeating: "This sentence keeps the synthesizer busy for a while. ", count: 20)
        let playback = try await engine.speak(SpeakOptions(long, locale: "en-US"))
        try await Task.sleep(nanoseconds: 300_000_000)
        playback.cancel(reason: "stop")
        let stopped = try await playback.result()
        XCTAssertEqual(stopped.finishReason, .cancelled)
    }

    /// Providers created, stopped mid-utterance and dropped one after another, as an app that
    /// rebuilds its engine per screen would. None may crash the process when the stopped
    /// utterance's late callbacks arrive (#251), and the synthesizers they retire are released
    /// after the grace period instead of accumulating for the life of the process.
    func testDiscardedProvidersReleaseTheirSynthesizersAfterStoppedSpeech() async throws {
        let providers = 4
        let retiredBefore = SystemAppleSpeechRuntime.retiredSynthesizers.total
        let long = String(repeating: "This sentence keeps the synthesizer busy for a while. ", count: 20)
        for _ in 0..<providers {
            let registry = ProviderRegistry()
            try registry.register(AppleSystemSpeechProvider())
            let engine = IndeRun(
                registry: registry,
                hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
            )
            let playback: SpeechPlayback
            do {
                playback = try await engine.speak(SpeakOptions(long, locale: "en-US"))
            } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
                throw XCTSkip("Speech synthesis is unavailable on this host: \(error.message)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            playback.cancel(reason: "stop")
            let stopped = try await playback.result()
            XCTAssertEqual(stopped.finishReason, .cancelled)
        }

        // Each provider retires its synthesizer once its last run has let go of it, which a slow
        // simulator can take a while to do; every retired one must then be freed within the grace
        // period.
        var retirement = SystemAppleSpeechRuntime.retiredSynthesizers
        let retiredBy = Date().addingTimeInterval(60)
        while Date() < retiredBy, retirement.total - retiredBefore < providers {
            try await Task.sleep(nanoseconds: 200_000_000)
            retirement = SystemAppleSpeechRuntime.retiredSynthesizers
        }
        XCTAssertEqual(retirement.total - retiredBefore, providers, "providers that retired their synthesizer")
        let freedBy = Date().addingTimeInterval(SystemAppleSpeechRuntime.retirementGrace * 2)
        while Date() < freedBy, retirement.pending > 0 {
            try await Task.sleep(nanoseconds: 200_000_000)
            retirement = SystemAppleSpeechRuntime.retiredSynthesizers
        }
        XCTAssertEqual(retirement.pending, 0, "retired synthesizers still held after the grace period")
    }

    private func speakWithin(seconds: UInt64, _ engine: IndeRun, _ options: SpeakOptions) async throws -> SpokenSpeech {
        let playback: SpeechPlayback
        do {
            playback = try await engine.speak(options)
        } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
            throw XCTSkip("Speech synthesis is unavailable on this host: \(error.message)")
        }
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

    private func readAll(_ engine: IndeRun, _ artifactId: String, chunk: Int) async throws -> Data {
        var bytes = Data()
        var offset = 0
        while true {
            let read = try await engine.readArtifact(
                request: ArtifactReadRequest(artifactId: artifactId, maxBytes: chunk, offset: offset)
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

