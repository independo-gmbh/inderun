import Foundation
import XCTest
@testable import IndeRunAppleProviders
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunOnnxProviders
@testable import IndeRunSwift

/// The latency scenarios of the shared corpus (`benchmark` in
/// `contracts/fixtures/speech/utterance-corpus.json`, #251), run through the public speech API
/// against every entry of `targets`.
///
/// Opt-in, because the scenarios play audio for minutes: set `INDERUN_SPEECH_BENCHMARK=1`
/// (`swift test`), or `TEST_RUNNER_INDERUN_SPEECH_BENCHMARK=1` in front of `xcodebuild test` for a
/// simulator or device. Each sample prints one `INDERUN-BENCH` line and each scenario one
/// `INDERUN-BENCH-SUMMARY` line, with ids and measurements but never utterance text, for
/// `docs/verification/system-speech.md`.
///
/// Environment (all optional):
/// - `INDERUN_SPEECH_BENCHMARK_MODEL_DIR`: a model package directory; adds a neural ONNX target.
/// - `INDERUN_SPEECH_BENCHMARK_MODEL_ID`: the model catalog entry id to record for the neural target
///   (for example `articulino-de-en-int8`); default is the package id.
/// - `INDERUN_SPEECH_BENCHMARK_OUT`: a directory, created before the first scenario; each target writes one
///   `SpeechBenchmarkReport` there.
/// - `INDERUN_SPEECH_BENCHMARK_SDK_VERSION`: the SDK version to record, default `dev`.
final class SpeechBenchmarkTests: XCTestCase {
    /// What a benchmark runs against: a provider, optionally pinned to one voice. Any provider that
    /// declares `text_to_speech` fits — a neural ONNX or Core ML provider, or the system provider
    /// pinned to a custom `AVSpeechSynthesisProviderAudioUnit` voice, which the system lists like
    /// any other voice. Add an entry here to compare it; the scenarios stay the same.
    struct Target {
        let name: String
        let providerId: String
        let makeProvider: () throws -> Built
        var hostServices: () -> HostServices = {
            HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        }
        var voice: SpeechVoice?
        var execution = SpeechExecutionOptions(privacy: .localRequired)
        var model: String?
        var variant: String?
        var checksums: [String: String]?
        var locality = "on_device"
        /// Also renders the corpus's `extendedUtterances` once in `render_speed`.
        var rendersExtended = false
    }

    /// A provider and the neural speech runtime made for it alone, if any. The provider does not
    /// close that runtime, so whoever made the `Built` closes it (``close()``).
    struct Built {
        let provider: any ProviderAdapter
        var runtime: (any NeuralSpeechRuntime)?

        func close() async {
            await runtime?.close()
        }
    }

    static func targets(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [Target] {
        var targets = [
            Target(
                name: "apple_system_speech", providerId: AppleSystemSpeechProvider().describe().id,
                makeProvider: { Built(provider: AppleSystemSpeechProvider()) }
            ),
        ]
        if let directory = environment["INDERUN_SPEECH_BENCHMARK_MODEL_DIR"] {
            targets.append(try await neuralTarget(
                directory: URL(fileURLWithPath: directory), modelId: environment["INDERUN_SPEECH_BENCHMARK_MODEL_ID"]
            ))
        }
        return targets
    }

    /// The package at `directory`, with `source` pointed at it, run through the neural speech
    /// provider `makeProvider` builds (the neural provider on the ONNX runtime by default). `name` defaults to `articulino_<variant>`.
    private static func neuralTarget(
        directory: URL, modelId: String?, name: String? = nil,
        makeProvider: @escaping (ModelPackage) -> Built = { package in
            let runtime = OnnxNeuralSpeechRuntime()
            return Built(provider: NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: runtime)), runtime: runtime)
        }
    ) async throws -> Target {
        let data = try Data(contentsOf: directory.appendingPathComponent("model-package.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["source"] = ["sourceType": "filesystem", "ref": directory.path]
        let package = try JSONDecoder().decode(ModelPackage.self, from: JSONSerialization.data(withJSONObject: json))
        let variant = package.variant
        let probe = makeProvider(package)
        let providerId = probe.provider.describe().id
        await probe.close()
        return Target(
            name: name ?? "articulino_\(variant ?? "default")",
            providerId: providerId,
            makeProvider: { makeProvider(package) },
            hostServices: { DefaultHostServices.make() },
            model: modelId ?? package.id,
            variant: variant,
            checksums: package.integrity?.checksums,
            rendersExtended: true
        )
    }

    // MARK: - Fixture

    struct Scenario: Decodable {
        let id: String
        let delivery: String
        let utteranceIds: [String]
        let trials: Int
        let cancelAfterMs: UInt64?
    }

    private struct Corpus: Decodable {
        struct Utterance: Decodable {
            let id: String
            let locale: String
            let text: String
        }

        struct Benchmark: Decodable {
            let scenarios: [Scenario]
        }

        let utterances: [Utterance]
        let extendedUtterances: [Utterance]?
        let benchmark: Benchmark
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

    // MARK: - Samples

    typealias Sample = SpeechBenchmarkReport.Sample

    private final class Run {
        let corpus: Corpus
        let scenario: Scenario
        let target: Target
        var samples: [Sample] = []
        /// Every engine this run built that is still open, with the provider made for it.
        private var open: [(engine: IndeRun, built: Built)] = []

        init(corpus: Corpus, scenario: Scenario, target: Target) {
            self.corpus = corpus
            self.scenario = scenario
            self.target = target
        }

        func utterance(_ index: Int) throws -> Corpus.Utterance {
            let id = scenario.utteranceIds[index]
            return try XCTUnwrap(corpus.utterances.first { $0.id == id }, "no utterance \(id)")
        }

        func engine() throws -> IndeRun {
            let made = try target.makeProvider()
            let registry = ProviderRegistry()
            try registry.register(made.provider)
            let engine = IndeRun(registry: registry, hostServices: target.hostServices())
            open.append((engine, made))
            return engine
        }

        /// Runs one trial on an engine of its own and closes it, with its runtime, when the trial
        /// ends, so a later trial does not run beside an earlier one's loaded graphs.
        func trial(_ body: (IndeRun) async throws -> Void) async throws {
            let engine = try engine()
            do {
                try await body(engine)
            } catch {
                await close(engine)
                throw error
            }
            await close(engine)
        }

        private func close(_ engine: IndeRun) async {
            guard let index = open.firstIndex(where: { $0.engine === engine }) else { return }
            let entry = open.remove(at: index)
            await entry.engine.close()
            await entry.built.close()
        }

        /// Closes every engine this run built that is still open, each with its runtime.
        func close() async {
            for entry in open { await close(entry.engine) }
        }

        func options(_ utterance: Corpus.Utterance) -> SpeakOptions {
            SpeakOptions(utterance.text, locale: utterance.locale, voice: target.voice, execution: target.execution)
        }

        func record(
            _ step: String, _ utterance: Corpus.Utterance, _ metrics: [String: Double?],
            resolvedLocale: String? = nil, peakRssDeltaBytes: UInt64? = nil
        ) {
            var values = metrics.compactMapValues { $0 }
            if let peakRssDeltaBytes { values["peakRssDeltaBytes"] = Double(peakRssDeltaBytes) }
            samples.append(Sample(
                scenario: scenario.id,
                step: step,
                utteranceId: utterance.id,
                requestedLocale: utterance.locale,
                resolvedLocale: resolvedLocale,
                metrics: values,
                target: target.name
            ))
        }

        /// Runs `body` while sampling the process's peak footprint, and returns the rise above its start.
        func measuringPeak<T>(_ body: () async throws -> T) async rethrows -> (value: T, peakRssDeltaBytes: UInt64) {
            let sampler = PeakRssSampler()
            sampler.start()
            do {
                let value = try await body()
                return (value, sampler.stop())
            } catch {
                _ = sampler.stop()
                throw error
            }
        }

        /// Speaks to the end and records what the call took.
        func speak(_ engine: IndeRun, _ index: Int, step: String) async throws {
            try await speak(engine, try utterance(index), step: step)
        }

        func speak(_ engine: IndeRun, _ utterance: Corpus.Utterance, step: String) async throws {
            let started = Date()
            let (ending, peak) = try await measuringPeak { try await engine.speak(options(utterance)).result() }
            record(step, utterance, [
                "firstChunkMs": ending.timing?.firstChunkMs,
                "firstAudioMs": ending.timing?.firstAudioMs,
                "wallMs": Date().timeIntervalSince(started) * 1000,
                "durationMs": ending.timing?.durationMs,
            ], resolvedLocale: ending.speech?.locale, peakRssDeltaBytes: peak)
        }

        /// Renders to an artifact once and records what the render took.
        func render(_ engine: IndeRun, _ utterance: Corpus.Utterance, step: String) async throws {
            let started = Date()
            let (speech, peak) = try await measuringPeak {
                try await engine.generateSpeech(GenerateSpeechOptions(options(utterance)))
            }
            let renderMs = Date().timeIntervalSince(started) * 1000
            await engine.disposeArtifact(artifact: speech.artifact)
            let audioMs = speech.artifact.durationMs
            record(step, utterance, [
                "renderMs": renderMs,
                "audioMs": audioMs,
                "realTimeFactor": SpeechBenchmarkReport.realTimeFactor(renderMs: renderMs, audioMs: audioMs),
                "bytes": speech.artifact.byteLength.map(Double.init),
            ], resolvedLocale: speech.speech?.locale, peakRssDeltaBytes: peak)
        }
    }

    private typealias Handler = (Run) async throws -> Void

    /// One handler per scenario id. The `setup` text in the fixture is what each one does.
    private static let handlers: [String: Handler] = [
        "first_call_cold": { run in
            for trial in 0..<run.scenario.trials {
                try await run.trial { engine in
                    try await run.speak(engine, 0, step: trial == 0 ? "first in process" : "new instance")
                }
            }
        },
        "first_call_after_prepare": { run in
            for trial in 0..<run.scenario.trials {
                try await run.trial { engine in
                    let utterance = try run.utterance(0)
                    let started = Date()
                    let (_, peak) = try await run.measuringPeak {
                        try await engine.prepare(PrepareRequest(tasks: ["text_to_speech"], locale: utterance.locale)).result()
                    }
                    run.record(trial == 0 ? "prepare, first in process" : "prepare, new instance", utterance, [
                        "prepareMs": Date().timeIntervalSince(started) * 1000,
                    ], peakRssDeltaBytes: peak)
                    try await run.speak(engine, 0, step: trial == 0 ? "first in process" : "new instance")
                }
            }
        },
        "repeat_same_voice": { run in
            let engine = try run.engine()
            for call in 1...run.scenario.trials {
                try await run.speak(engine, 0, step: "call \(call)")
            }
        },
        "switch_language": { run in
            let engine = try run.engine()
            for index in run.scenario.utteranceIds.indices {
                let utterance = try run.utterance(index)
                try await run.speak(engine, index, step: "call \(index + 1) (\(utterance.locale))")
            }
        },
        "speak_after_stop": { run in
            let engine = try run.engine()
            try await run.speak(engine, 1, step: "warm-up")
            for _ in 0..<run.scenario.trials {
                let long = try run.utterance(0)
                let playback = try await engine.speak(run.options(long))
                try await Task.sleep(nanoseconds: (run.scenario.cancelAfterMs ?? 1500) * 1_000_000)
                let stopIssued = Date()
                playback.cancel(reason: "benchmark stop")
                let stopped = try await playback.result()
                // Playback that ended before the stop has no stop latency to report, and is not a failure.
                if stopped.finishReason == .cancelled {
                    run.record(
                        "stop", long, ["stopLatencyMs": Date().timeIntervalSince(stopIssued) * 1000],
                        resolvedLocale: stopped.speech?.locale
                    )
                }
                try await run.speak(engine, 1, step: "next after stop")
            }
        },
        "text_length": { run in
            let engine = try run.engine()
            try await run.speak(engine, 0, step: "warm-up")
            for index in run.scenario.utteranceIds.indices {
                try await run.speak(engine, index, step: index == 0 ? "short" : "long")
            }
        },
        "render_speed": { run in
            let engine = try run.engine()
            for index in run.scenario.utteranceIds.indices {
                let utterance = try run.utterance(index)
                for trial in 0...run.scenario.trials {
                    try await run.render(engine, utterance, step: trial == 0 ? "cold" : "warm")
                }
            }
            // The neural target renders its extended sentences once each, on the warmed engine.
            if run.target.rendersExtended {
                for utterance in run.corpus.extendedUtterances ?? [] {
                    try await run.render(engine, utterance, step: "extended")
                }
            }
        },
    ]

    // MARK: - Tests

    func testImplementsEveryBenchmarkScenarioAndNoOthers() throws {
        let ids = try Self.loadCorpus().benchmark.scenarios.map(\.id).sorted()
        XCTAssertEqual(ids, Self.handlers.keys.sorted())
    }

    func testRunsEveryScenarioAgainstEveryTarget() async throws {
        guard ProcessInfo.processInfo.environment["INDERUN_SPEECH_BENCHMARK"] != nil else {
            throw XCTSkip("Opt-in: set INDERUN_SPEECH_BENCHMARK=1 to run the speech benchmark.")
        }
        let corpus = try Self.loadCorpus()
        let environment = ProcessInfo.processInfo.environment
        let outDirectory = try environment["INDERUN_SPEECH_BENCHMARK_OUT"].map(SpeechBenchmarkReport.prepareOutputDirectory)
        for target in try await Self.targets(environment: environment) {
            var samples: [Sample] = []
            var skipped: [(scenario: String, reason: String)] = []
            let probe = try target.makeProvider()
            let declared = Set(
                (probe.provider.describe().taskCapabilities ?? [])
                    .filter { $0.kind == TaskKind.textToSpeech.rawValue }
                    .flatMap(\.outputs)
                    .map(\.delivery.rawValue)
            )
            await probe.close()
            for scenario in corpus.benchmark.scenarios {
                guard declared.contains(scenario.delivery) else {
                    let reason = "no \(scenario.delivery) delivery"
                    print("INDERUN-BENCH-SUMMARY apple \(target.name) \(scenario.id) unsupported: \(reason)")
                    skipped.append((scenario.id, reason))
                    continue
                }
                let run = Run(corpus: corpus, scenario: scenario, target: target)
                // Every engine and runtime the scenario built is closed however it ends, so no trial
                // keeps another's loaded graphs.
                do {
                    try await XCTUnwrap(Self.handlers[scenario.id])(run)
                    await run.close()
                } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
                    await run.close()
                    let reason = SpeechBenchmarkReport.skipReason(error)
                    print("INDERUN-BENCH-SUMMARY apple \(target.name) \(scenario.id) unavailable: \(reason)")
                    skipped.append((scenario.id, reason))
                    continue
                } catch {
                    await run.close()
                    throw error
                }
                report(run.samples)
                samples += run.samples
            }
            if let outDirectory {
                let written = try SpeechBenchmarkReport.build(
                    harness: "sdk_tests",
                    device: SpeechBenchmarkReport.hardwareModel(),
                    os: Self.operatingSystem(),
                    sdkVersion: environment["INDERUN_SPEECH_BENCHMARK_SDK_VERSION"] ?? "dev",
                    target: SpeechBenchmarkReport.Target(
                        name: target.name, providerId: target.providerId, model: target.model,
                        variant: target.variant, checksums: target.checksums, voiceId: target.voice?.id
                    ),
                    locality: target.locality,
                    samples: samples,
                    skipped: skipped,
                    createdAt: Date()
                ).write(to: outDirectory)
                print("INDERUN-BENCH-REPORT apple \(target.name) \(written.lastPathComponent)")
            }
        }
    }

    private static func operatingSystem() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(macOS)
        return "macOS \(number)"
        #elseif os(iOS)
        return "iOS \(number)"
        #else
        return number
        #endif
    }

    private func report(_ samples: [Sample]) {
        for sample in samples {
            var fields: [String: Any] = [
                "scenario": sample.scenario,
                "target": sample.target,
                "step": sample.step,
                "utteranceId": sample.utteranceId,
            ]
            for (name, value) in sample.metrics { fields[name] = (value * 10).rounded() / 10 }
            print("INDERUN-BENCH apple " + json(fields))
        }
        guard let first = samples.first else { return }
        // Grouped by step, so a cold call is never averaged with warm ones.
        var steps: [String] = []
        var grouped: [String: [Sample]] = [:]
        for sample in samples {
            let key = "\(sample.step) · \(sample.utteranceId)"
            if grouped[key] == nil { steps.append(key) }
            grouped[key, default: []].append(sample)
        }
        for key in steps {
            let group = grouped[key] ?? []
            let metrics = Set(group.flatMap(\.metrics.keys)).sorted().map { name -> String in
                let values = group.compactMap { $0.metrics[name] }.sorted()
                let median = values[values.count / 2]
                return "\(name) median \(format(median)) max \(format(values.last ?? 0)) n \(values.count)"
            }
            let summary = metrics.joined(separator: "; ")
            print("INDERUN-BENCH-SUMMARY apple \(first.target) \(first.scenario) [\(key)] \(summary)")
        }
    }

    /// Whole milliseconds, but two decimals for small values such as the real-time factor.
    private func format(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f", value) : String(Int(value.rounded()))
    }

    private func json(_ fields: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
