import Darwin
import Foundation
import IndeRunContracts
import IndeRunCore

/// The machine-readable result of one speech benchmark run against one target (#276), shaped by
/// `contracts/fixtures/speech/speech-benchmark-report.schema.json`. It carries utterance ids and
/// measurements, never utterance text, and a hardware model id, never a user-assigned device name.
struct SpeechBenchmarkReport: Encodable {
    struct Target {
        let name: String
        let providerId: String
        var model: String?
        var variant: String?
        var checksums: [String: String]?
        var voiceId: String?
    }

    /// One measured step. `target` only labels the `INDERUN-BENCH` log lines; the report leaves it out.
    struct Sample {
        let scenario: String
        let step: String
        let utteranceId: String
        let requestedLocale: String
        var resolvedLocale: String?
        var metrics: [String: Double]
        var target = ""

        init(
            scenario: String, step: String, utteranceId: String, requestedLocale: String,
            resolvedLocale: String? = nil, metrics: [String: Double], target: String = ""
        ) {
            self.scenario = scenario
            self.step = step
            self.utteranceId = utteranceId
            self.requestedLocale = requestedLocale
            self.resolvedLocale = resolvedLocale
            // JSON has no infinity or NaN; a metric that is not a number is not a measurement.
            self.metrics = metrics.filter { $0.value.isFinite }
            self.target = target
        }
    }

    struct Percentile {
        let scenario: String
        let step: String
        let utteranceId: String
        let metrics: [String: Double]
    }

    let harness: String
    let createdAt: Date
    let device: String
    let os: String
    let sdkVersion: String
    let target: Target
    /// Distinct locales in first-seen order; encoded as the top-level `requestedLocale` / `resolvedLocale`.
    let requestedLocales: [String]
    let resolvedLocales: [String]
    let locality: String
    let samples: [Sample]
    let skipped: [(scenario: String, reason: String)]
    let p50: [Percentile]
    let p95: [Percentile]

    static func build(
        harness: String, device: String, os: String, sdkVersion: String, target: Target, locality: String,
        samples: [Sample], skipped: [(scenario: String, reason: String)], createdAt: Date
    ) -> SpeechBenchmarkReport {
        SpeechBenchmarkReport(
            harness: harness, createdAt: createdAt, device: device, os: os, sdkVersion: sdkVersion, target: target,
            requestedLocales: distinct(samples.map(\.requestedLocale)),
            resolvedLocales: distinct(samples.compactMap(\.resolvedLocale)),
            locality: locality, samples: samples, skipped: skipped,
            p50: percentiles(samples, 0.5), p95: percentiles(samples, 0.95)
        )
    }

    /// Render time over audio time; nil when the audio has no length, so a zero-length artifact never records infinity.
    static func realTimeFactor(renderMs: Double, audioMs: Double?) -> Double? {
        guard let audioMs, audioMs > 0 else { return nil }
        return renderMs / audioMs
    }

    /// Why a scenario was skipped: the error class and `details.code` only. An error message can echo the
    /// request, and a report never carries utterance text.
    static func skipReason(_ error: Error) -> String {
        guard let exception = error as? IndeRunException else { return String(describing: type(of: error)) }
        if let code = exception.details?["code"]?.value as? String { return "\(exception.errorClass.rawValue): \(code)" }
        return exception.errorClass.rawValue
    }

    /// Creates `path` (and parents) before the first scenario runs, so a bad path fails at once rather than after
    /// minutes of playback.
    static func prepareOutputDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Nearest rank: index `ceil(q * n) - 1` of the ascending values. `sorted` must not be empty.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))]
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Per `(scenario, step, utterance)`, so a cold call is never pooled with warm ones.
    private static func percentiles(_ samples: [Sample], _ q: Double) -> [Percentile] {
        struct Key: Hashable { let scenario, step, utteranceId: String }
        var order: [Key] = []
        var groups: [Key: [Sample]] = [:]
        for sample in samples {
            let key = Key(scenario: sample.scenario, step: sample.step, utteranceId: sample.utteranceId)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(sample)
        }
        return order.map { key in
            let group = groups[key] ?? []
            var metrics: [String: Double] = [:]
            for name in Set(group.flatMap { $0.metrics.keys }) {
                let values = group.compactMap { $0.metrics[name] }.sorted()
                if !values.isEmpty { metrics[name] = percentile(values, q) }
            }
            return Percentile(scenario: key.scenario, step: key.step, utteranceId: key.utteranceId, metrics: metrics)
        }
    }

    // MARK: - Output

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Writes `<harness>-<target>-<device>-<yyyy-MM-dd>.json` into `directory`, creating it first.
    func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = [harness, Self.fileSafe(target.name), Self.fileSafe(device), formatter.string(from: createdAt)]
            .joined(separator: "-") + ".json"
        let url = directory.appendingPathComponent(name)
        try encodedData().write(to: url, options: .atomic)
        return url
    }

    /// Anything outside `[A-Za-z0-9._-]` becomes `-`.
    private static func fileSafe(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            let ascii = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            return ascii ? Character(scalar) : "-"
        })
    }

    /// The hardware model id: `hw.model` on macOS, `utsname.machine` elsewhere. Never the device's name.
    static func hardwareModel() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        #endif
    }

    private enum CodingKeys: String, CodingKey {
        case schema, harness, createdAt, device, os, sdkVersion, target, requestedLocale, resolvedLocale
        case locality, samples, skipped, p50, p95
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("inderun-speech-benchmark/1", forKey: .schema)
        try container.encode(harness, forKey: .harness)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(device, forKey: .device)
        try container.encode(os, forKey: .os)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(target, forKey: .target)
        try container.encode(requestedLocales, forKey: .requestedLocale)
        try container.encode(resolvedLocales, forKey: .resolvedLocale)
        try container.encode(locality, forKey: .locality)
        try container.encode(samples, forKey: .samples)
        try container.encode(skipped.map { SkippedEntry(scenario: $0.scenario, reason: $0.reason) }, forKey: .skipped)
        try container.encode(p50, forKey: .p50)
        try container.encode(p95, forKey: .p95)
    }

    private struct SkippedEntry: Encodable {
        let scenario: String
        let reason: String
    }
}

extension SpeechBenchmarkReport.Target: Encodable {}

extension SpeechBenchmarkReport.Sample: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(scenario, forKey: DynamicKey("scenario"))
        try container.encode(step, forKey: DynamicKey("step"))
        try container.encode(utteranceId, forKey: DynamicKey("utteranceId"))
        try container.encode(requestedLocale, forKey: DynamicKey("requestedLocale"))
        try container.encodeIfPresent(resolvedLocale, forKey: DynamicKey("resolvedLocale"))
        for (name, value) in metrics { try container.encode(value, forKey: DynamicKey(name)) }
    }
}

extension SpeechBenchmarkReport.Percentile: Encodable {}

private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Samples the process's physical footprint (`task_vm_info.phys_footprint`, as
/// `tools/neural-speech/ios-device-bench.patch` does) every `interval` between `start()` and
/// `stop()`, and reports how far the peak rose above the footprint at `start()`.
final class PeakRssSampler: @unchecked Sendable {
    private let read: @Sendable () -> UInt64
    private let interval: Duration
    private let lock = NSLock()
    private var baseline: UInt64 = 0
    private var peak: UInt64 = 0
    private var polling: Task<Void, Never>?

    init(read: @escaping @Sendable () -> UInt64 = PeakRssSampler.physFootprint, interval: Duration = .milliseconds(20)) {
        self.read = read
        self.interval = interval
    }

    func start() {
        precondition(polling == nil, "PeakRssSampler is already started")
        let first = read()
        lock.lock()
        baseline = first
        peak = first
        lock.unlock()
        polling = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                sample()
            }
        }
    }

    /// Reads once more and folds the reading into the peak. The polling task calls this every `interval`.
    func sample() {
        let value = read()
        lock.lock()
        peak = max(peak, value)
        lock.unlock()
    }

    /// Stops polling and returns the peak minus the footprint at `start()`, at least 0.
    func stop() -> UInt64 {
        polling?.cancel()
        polling = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return peak > baseline ? peak - baseline : 0
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
