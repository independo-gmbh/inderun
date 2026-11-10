import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore

/// The report builder behind `SpeechBenchmarkTests` (#276). Not gated: it measures nothing.
final class SpeechBenchmarkReportTests: XCTestCase {
    private let target = SpeechBenchmarkReport.Target(name: "system", providerId: "apple_system_speech")

    private func sample(
        _ scenario: String, _ step: String, _ metrics: [String: Double] = [:],
        utterance: String = "u1", requested: String = "de-DE", resolved: String? = nil
    ) -> SpeechBenchmarkReport.Sample {
        SpeechBenchmarkReport.Sample(
            scenario: scenario, step: step, utteranceId: utterance,
            requestedLocale: requested, resolvedLocale: resolved, metrics: metrics
        )
    }

    private func build(
        _ samples: [SpeechBenchmarkReport.Sample],
        skipped: [(scenario: String, reason: String)] = [],
        device: String = "Mac16,1"
    ) -> SpeechBenchmarkReport {
        SpeechBenchmarkReport.build(
            harness: "sdk_tests", device: device, os: "macOS 27.2", sdkVersion: "dev", target: target,
            locality: "on_device", samples: samples, skipped: skipped,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func encoded(_ report: SpeechBenchmarkReport) throws -> [String: Any] {
        let data = try report.encodedData()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPercentileNearestRank() {
        let ten = (1...10).map(Double.init)
        XCTAssertEqual(SpeechBenchmarkReport.percentile(ten, 0.5), 5)
        XCTAssertEqual(SpeechBenchmarkReport.percentile(ten, 0.95), 10)
        XCTAssertEqual(SpeechBenchmarkReport.percentile([7], 0.5), 7)
        XCTAssertEqual(SpeechBenchmarkReport.percentile([7], 0.95), 7)
    }

    func testGroupsByScenarioStepUtterance() {
        let report = build([
            sample("repeat", "cold", ["wallMs": 900]),
            sample("repeat", "cold", ["wallMs": 1100]),
            sample("repeat", "warm", ["wallMs": 100]),
            sample("repeat", "warm", ["wallMs": 120]),
            sample("repeat", "warm", ["wallMs": 110]),
        ])
        XCTAssertEqual(report.p50.count, 2)
        XCTAssertEqual(report.p50.first { $0.step == "cold" }?.metrics["wallMs"], 900)
        XCTAssertEqual(report.p50.first { $0.step == "warm" }?.metrics["wallMs"], 110)
        XCTAssertEqual(report.p95.first { $0.step == "cold" }?.metrics["wallMs"], 1100)
        XCTAssertEqual(report.p95.first { $0.step == "warm" }?.metrics["wallMs"], 120)
    }

    func testSingleSampleGivesEqualPercentiles() {
        let report = build([sample("s", "warm", ["wallMs": 42])])
        XCTAssertEqual(report.p50.first?.metrics["wallMs"], 42)
        XCTAssertEqual(report.p95.first?.metrics["wallMs"], 42)
    }

    func testEmptySamplesGiveEmptyPercentiles() throws {
        let report = build([])
        XCTAssertTrue(report.p50.isEmpty)
        XCTAssertTrue(report.p95.isEmpty)
        let json = try encoded(report)
        XCTAssertEqual((json["p50"] as? [Any])?.count, 0)
        XCTAssertEqual((json["samples"] as? [Any])?.count, 0)
    }

    func testSkippedScenarioIsListedAndAbsentFromPercentiles() throws {
        let report = build(
            [sample("repeat", "warm", ["wallMs": 100])],
            skipped: [(scenario: "speak_after_stop", reason: "no streaming delivery")]
        )
        let json = try encoded(report)
        let skipped = try XCTUnwrap(json["skipped"] as? [[String: String]])
        XCTAssertEqual(skipped, [["scenario": "speak_after_stop", "reason": "no streaming delivery"]])
        XCTAssertFalse(report.p50.contains { $0.scenario == "speak_after_stop" })
        XCTAssertFalse(report.p95.contains { $0.scenario == "speak_after_stop" })
    }

    func testReportNeverContainsUtteranceText() throws {
        let corpusURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/speech/utterance-corpus.json")
        let corpus = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any]
        )
        let entries = ((corpus["utterances"] as? [[String: Any]]) ?? [])
            + ((corpus["extendedUtterances"] as? [[String: Any]]) ?? [])
        XCTAssertFalse(entries.isEmpty)
        let samples = entries.map {
            sample("render_speed", "warm", ["wallMs": 1], utterance: $0["id"] as? String ?? "", requested: $0["locale"] as? String ?? "de-DE")
        }
        let text = try String(decoding: build(samples).encodedData(), as: UTF8.self)
        for entry in entries {
            let utterance = try XCTUnwrap(entry["text"] as? String)
            XCTAssertFalse(text.contains(utterance), "report leaked text of \(entry["id"] ?? "?")")
        }
    }

    func testRequestedAndResolvedLocalesAreDistinctFirstSeen() {
        let report = build([
            sample("s", "a", requested: "de-DE", resolved: "de-DE"),
            sample("s", "b", requested: "en-US", resolved: "en-US"),
            sample("s", "c", requested: "de-DE", resolved: "de-DE"),
        ])
        XCTAssertEqual(report.requestedLocales, ["de-DE", "en-US"])
        XCTAssertEqual(report.resolvedLocales, ["de-DE", "en-US"])
    }

    func testEncodedReportUsesSchemaShape() throws {
        let json = try encoded(build([sample("s", "warm", ["wallMs": 5], resolved: "de-DE")]))
        XCTAssertEqual(json["schema"] as? String, "inderun-speech-benchmark/1")
        XCTAssertEqual(json["harness"] as? String, "sdk_tests")
        XCTAssertEqual(json["locality"] as? String, "on_device")
        XCTAssertTrue((json["createdAt"] as? String ?? "").hasPrefix("2027-"))
        XCTAssertEqual(json["requestedLocale"] as? [String], ["de-DE"])
        XCTAssertEqual(json["resolvedLocale"] as? [String], ["de-DE"])
        let first = try XCTUnwrap((json["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["wallMs"] as? Double, 5)
        XCTAssertNil(first["target"])
    }

    func testWriteCreatesMissingDirectoryAndOneFilePerTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-bench-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let other = SpeechBenchmarkReport.Target(name: "articulino_onnx-int8", providerId: "neural")
        let first = try build([], device: "Mac 16/1 (Bob's)").write(to: directory)
        let second = try SpeechBenchmarkReport.build(
            harness: "sdk_tests", device: "Mac16,1", os: "macOS", sdkVersion: "dev", target: other,
            locality: "on_device", samples: [], skipped: [], createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        ).write(to: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "sdk_tests-system-Mac-16-1--Bob-s--2027-01-15.json")
        XCTAssertEqual(second.lastPathComponent, "sdk_tests-articulino_onnx-int8-Mac16-1-2027-01-15.json")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any]
        XCTAssertEqual(parsed?["schema"] as? String, "inderun-speech-benchmark/1")
    }

    func testSkipReasonKeepsTheClassAndCodeNeverTheMessage() {
        let withCode = IndeRunException(
            errorClass: .CapabilityMismatch, message: "could not say: private words",
            details: ["code": JSONAny("no_delivery")]
        )
        XCTAssertEqual(SpeechBenchmarkReport.skipReason(withCode), "CapabilityMismatch: no_delivery")
        let bare = IndeRunException(errorClass: .CapabilityMismatch, message: "private words")
        XCTAssertEqual(SpeechBenchmarkReport.skipReason(bare), "CapabilityMismatch")
        struct Odd: Error, CustomStringConvertible { var description: String { "private words" } }
        XCTAssertEqual(SpeechBenchmarkReport.skipReason(Odd()), "Odd")
    }

    func testRealTimeFactorNeedsPositiveAudio() {
        XCTAssertEqual(SpeechBenchmarkReport.realTimeFactor(renderMs: 100, audioMs: 2000), 0.05)
        XCTAssertNil(SpeechBenchmarkReport.realTimeFactor(renderMs: 100, audioMs: 0))
        XCTAssertNil(SpeechBenchmarkReport.realTimeFactor(renderMs: 100, audioMs: nil))
    }

    func testNonFiniteMetricsAreDroppedFromSamples() throws {
        let report = build([sample("s", "a", ["wallMs": 5, "realTimeFactor": .infinity, "renderMs": .nan])])
        XCTAssertEqual(report.samples[0].metrics, ["wallMs": 5])
        XCTAssertNoThrow(try report.encodedData())
    }

    func testPrepareOutputDirectoryCreatesItAndRejectsAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b")
        let made = try SpeechBenchmarkReport.prepareOutputDirectory(nested.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let file = root.appendingPathComponent("plain")
        try Data().write(to: file)
        XCTAssertThrowsError(try SpeechBenchmarkReport.prepareOutputDirectory(file.path))
    }

    func testPeakRssSamplerReportsPeakMinusStart() {
        let values = ReadingSequence([100, 180, 150])
        // An hour-long interval keeps the background loop out of the way, so the readings are exact.
        let sampler = PeakRssSampler(read: { values.next() }, interval: .seconds(3600))
        sampler.start()
        sampler.sample()
        sampler.sample()
        XCTAssertEqual(sampler.stop(), 80)
    }

    func testPeakRssSamplerClampsAtZero() {
        let values = ReadingSequence([100, 60])
        let sampler = PeakRssSampler(read: { values.next() }, interval: .seconds(3600))
        sampler.start()
        XCTAssertEqual(sampler.stop(), 0)
    }

    func testHardwareModelIsNotEmpty() {
        XCTAssertFalse(SpeechBenchmarkReport.hardwareModel().isEmpty)
    }
}

/// Hands out the given readings in order, then repeats the last.
private final class ReadingSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) { self.values = values }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}
