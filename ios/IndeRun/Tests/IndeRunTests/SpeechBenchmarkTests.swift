import Foundation
import XCTest
@testable import IndeRunAppleProviders
@testable import IndeRunContracts
@testable import IndeRunCore
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
final class SpeechBenchmarkTests: XCTestCase {
    /// What a benchmark runs against: a provider, optionally pinned to one voice. Any provider that
    /// declares `text_to_speech` fits — a neural ONNX or Core ML provider, or the system provider
    /// pinned to a custom `AVSpeechSynthesisProviderAudioUnit` voice, which the system lists like
    /// any other voice. Add an entry here to compare it; the scenarios stay the same.
    struct Target {
        let name: String
        let makeProvider: () throws -> any ProviderAdapter
        var voice: SpeechVoice?
        var execution = SpeechExecutionOptions(privacy: .localRequired)
    }

    static let targets: [Target] = [
        Target(name: "apple_system_speech", makeProvider: { AppleSystemSpeechProvider() }),
    ]

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

    struct Sample {
        let scenario: String
        let target: String
        /// The sample's position within its scenario, e.g. `call 3` or `cold`.
        let step: String
        let utteranceId: String
        var metrics: [String: Double]
    }

    private final class Run {
        let corpus: Corpus
        let scenario: Scenario
        let target: Target
        var samples: [Sample] = []

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
            let registry = ProviderRegistry()
            try registry.register(try target.makeProvider())
            return IndeRun(
                registry: registry,
                hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
            )
        }

        func options(_ utterance: Corpus.Utterance) -> SpeakOptions {
            SpeakOptions(utterance.text, locale: utterance.locale, voice: target.voice, execution: target.execution)
        }

        func record(_ step: String, _ utterance: Corpus.Utterance, _ metrics: [String: Double?]) {
            samples.append(Sample(
                scenario: scenario.id,
                target: target.name,
                step: step,
                utteranceId: utterance.id,
                metrics: metrics.compactMapValues { $0 }
            ))
        }

        /// Speaks to the end and records what the call took.
        func speak(_ engine: IndeRun, _ index: Int, step: String) async throws {
            let utterance = try utterance(index)
            let started = Date()
            let ending = try await engine.speak(options(utterance)).result()
            record(step, utterance, [
                "firstAudioMs": ending.timing?.firstAudioMs,
                "wallMs": Date().timeIntervalSince(started) * 1000,
                "durationMs": ending.timing?.durationMs,
            ])
        }
    }

    private typealias Handler = (Run) async throws -> Void

    /// One handler per scenario id. The `setup` text in the fixture is what each one does.
    private static let handlers: [String: Handler] = [
        "first_call_cold": { run in
            for trial in 0..<run.scenario.trials {
                try await run.speak(try run.engine(), 0, step: trial == 0 ? "first in process" : "new instance")
            }
        },
        "first_call_after_prepare": { run in
            for trial in 0..<run.scenario.trials {
                let engine = try run.engine()
                let utterance = try run.utterance(0)
                let started = Date()
                _ = try await engine.prepare(PrepareRequest(tasks: ["text_to_speech"], locale: utterance.locale)).result()
                run.record(trial == 0 ? "prepare, first in process" : "prepare, new instance", utterance, [
                    "prepareMs": Date().timeIntervalSince(started) * 1000,
                ])
                try await run.speak(engine, 0, step: trial == 0 ? "first in process" : "new instance")
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
                XCTAssertEqual(stopped.finishReason, .cancelled)
                run.record("stop", long, ["stopLatencyMs": Date().timeIntervalSince(stopIssued) * 1000])
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
                    let started = Date()
                    let speech = try await engine.generateSpeech(GenerateSpeechOptions(run.options(utterance)))
                    let renderMs = Date().timeIntervalSince(started) * 1000
                    await engine.disposeArtifact(artifact: speech.artifact)
                    let audioMs = speech.artifact.durationMs
                    run.record(trial == 0 ? "cold" : "warm", utterance, [
                        "renderMs": renderMs,
                        "audioMs": audioMs,
                        "realTimeFactor": audioMs.map { renderMs / $0 },
                        "bytes": speech.artifact.byteLength.map(Double.init),
                    ])
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
        for target in Self.targets {
            let declared = Set(
                (try target.makeProvider().describe().taskCapabilities ?? [])
                    .filter { $0.kind == TaskKind.textToSpeech.rawValue }
                    .flatMap(\.outputs)
                    .map(\.delivery.rawValue)
            )
            for scenario in corpus.benchmark.scenarios {
                guard declared.contains(scenario.delivery) else {
                    print("INDERUN-BENCH-SUMMARY apple \(target.name) \(scenario.id) unsupported: no \(scenario.delivery) delivery")
                    continue
                }
                let run = Run(corpus: corpus, scenario: scenario, target: target)
                do {
                    try await XCTUnwrap(Self.handlers[scenario.id])(run)
                } catch let error as IndeRunException where error.errorClass == .CapabilityMismatch {
                    print("INDERUN-BENCH-SUMMARY apple \(target.name) \(scenario.id) unavailable: \(error.message)")
                    continue
                }
                report(run.samples)
            }
        }
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
