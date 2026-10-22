import AVFoundation
import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// Real retrievable audio through the artifact store (#244): `AVSpeechSynthesizer.write`
/// renders actual speech, and this test-scoped provider hands it over as a 16-bit PCM WAV
/// artifact that the test then reads back through `readArtifact`.
///
/// This is a sample, not the Apple system speech provider (#247): it ships nowhere, declares
/// no playback, performs no capability checks and has no Provider Matrix row. It exists to
/// prove the artifact transport with bytes a real synthesizer produced. The encoding is
/// documented in `ios/IndeRun/README.md`.
private final class SpeechSynthesisSampleProvider: ProviderAdapter, @unchecked Sendable {
    static let id = "apple_speech_artifact_sample"

    /// How long to wait for the synthesizer before the test is skipped rather than failed:
    /// a host without voices, or a CI runner without an audio stack, may never call back.
    static let timeout: TimeInterval = 10

    /// Set when the host could not synthesize at all, so the test skips instead of failing.
    /// Anything else the run throws is a real failure of the artifact path.
    private(set) var skipReason: String?

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
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
            cancel: .none,
            tasks: ["text_to_speech"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_speech",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(run: true, stream: false),
                    cancel: .none,
                    outputs: [ProviderTaskOutput(delivery: .artifact, mediaTypes: ["audio/wav"])],
                    locales: ["en-US"]
                )
            ]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let speech = try XCTUnwrap(request.speech)
        let pcm: RenderedSpeech
        do {
            pcm = try await SpeechRenderer.render(text: speech.text, locale: speech.locale)
        } catch let skip as XCTSkip {
            skipReason = "\(skip)"
            throw skip
        }
        let wav = WAVEncoder.encode(pcm)

        let writer = context.artifacts.create(
            spec: ArtifactSpec(mediaType: "audio/wav", durationMs: pcm.durationMs)
        )
        try writer.write(wav)
        let artifact = try writer.finish()

        return TaskResult(
            runId: context.runId,
            output: TaskOutput(artifact: artifact, speech: SpeechOutput(locale: speech.locale, voice: nil)),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: Self.id, totalMs: 0)
        )
    }
}

/// Mono 16-bit signed little-endian samples at `sampleRate`.
private struct RenderedSpeech {
    var samples: Data
    var sampleRate: Int

    var durationMs: Double {
        Double(samples.count / 2) / Double(sampleRate) * 1000
    }
}

private enum SpeechRenderer {
    struct NoAudio: Error {}

    /// Renders `text` with the first voice for `locale`, converting each buffer the synthesizer
    /// delivers to 16-bit PCM from its first channel. A zero-length buffer ends the utterance.
    static func render(text: String, locale: String) async throws -> RenderedSpeech {
        guard let voice = AVSpeechSynthesisVoice(language: locale) else {
            throw XCTSkip("No \(locale) voice is installed on this host.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let synthesizer = AVSpeechSynthesizer()
        let collector = Collector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.onFinish = { result in continuation.resume(with: result) }
            DispatchQueue.global().asyncAfter(deadline: .now() + SpeechSynthesisSampleProvider.timeout) {
                collector.finish(.failure(XCTSkip("The synthesizer delivered no audio within the timeout.")))
            }
            synthesizer.write(utterance) { buffer in
                // Keeps the synthesizer alive until the utterance is done.
                withExtendedLifetime(synthesizer) {
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        collector.finish()
                    } else {
                        collector.append(pcm)
                    }
                }
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples = Data()
        private var sampleRate: Int?
        private var finished = false
        var onFinish: ((Result<RenderedSpeech, Error>) -> Void)?

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                sampleRate = sampleRate ?? Int(buffer.format.sampleRate)
                samples.append(int16Samples(buffer))
            }
        }

        func finish(_ failure: Result<RenderedSpeech, Error>? = nil) {
            let result: Result<RenderedSpeech, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                if let failure { return failure }
                guard let sampleRate, !samples.isEmpty else { return .failure(NoAudio()) }
                return .success(RenderedSpeech(samples: samples, sampleRate: sampleRate))
            }
            if let result { onFinish?(result) }
        }

        private func int16Samples(_ buffer: AVAudioPCMBuffer) -> Data {
            let frames = Int(buffer.frameLength)
            var out = Data(capacity: frames * 2)
            func append(_ value: Int16) {
                withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            }
            if let channel = buffer.int16ChannelData?[0] {
                for index in 0..<frames { append(channel[index]) }
            } else if let channel = buffer.floatChannelData?[0] {
                for index in 0..<frames {
                    append(Int16(max(-1, min(1, channel[index])) * Float(Int16.max)))
                }
            }
            return out
        }
    }
}

/// A canonical 44-byte RIFF/WAVE header (PCM, mono, 16-bit) followed by the samples.
private enum WAVEncoder {
    static func encode(_ speech: RenderedSpeech) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let byteRate = UInt32(speech.sampleRate * 2)
        append("RIFF")
        append32(UInt32(36 + speech.samples.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(speech.sampleRate))
        append32(byteRate)
        append16(2) // block align
        append16(16) // bits per sample
        append("data")
        append32(UInt32(speech.samples.count))
        data.append(speech.samples)
        return data
    }
}

final class AppleSpeechArtifactSampleTests: XCTestCase {
    func testSynthesizedSpeechIsARetrievableWAVArtifact() async throws {
        let provider = SpeechSynthesisSampleProvider()
        let registry = ProviderRegistry()
        try registry.register(provider)
        let engine = IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
        let request = TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            speech: SpeechInput(locale: "en-US", localeMatch: .exact, text: "Your appointment is at 3 pm.", voice: nil),
            delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: ["audio/wav"], mode: .artifact)
        )

        let result: TaskResult
        do {
            result = try await engine.run(request: request)
        } catch {
            // The provider's XCTSkip reaches the engine as a provider failure; surface only that
            // as a skip, so a broken artifact path still fails the test.
            if let reason = provider.skipReason {
                throw XCTSkip("Speech synthesis is unavailable on this host: \(reason)")
            }
            throw error
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
