import Foundation

/// The constants of the upstream Articulino `config.json` the pipeline needs.
public struct ArticulinoConfig: Sendable, Equatable {
    public let sampleRate: Int
    public let latentDim: Int
    public let samplesPerFrame: Int
    public let durationUnitsPerFrame: Int
    public let prefixFrames: Int
    public let decoderLeadInFrames: Int
    public let maxDurationUnits: Float
    public let times: [Float]
    public let charset: String
    public let languages: [String: Int]
    public let lowShelfDb: Double
    public let lowShelfHz: Double
    public let shelfSlope: Double
    public let peak: Double

    /// Upper bound of `max_duration_units`. With the voice's `letter_rate` held to 1-100 and `speed` to at
    /// least 0.7, it bounds every duration and so the frame count of a sentence.
    static let maxDurationUnitsCap: Double = 100_000

    private static func malformed(_ why: String) -> NeuralSpeechRuntimeError {
        NeuralSpeechRuntimeError(kind: .capability, message: "pipeline config malformed: \(why)")
    }

    private static func missing(_ key: String) -> NeuralSpeechRuntimeError {
        malformed("missing '\(key)'")
    }

    /// `value` as an exact integer within `range`; checked before converting, so no value traps.
    private static func integer(_ value: Double, _ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw malformed("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(value)
    }

    private static func number(_ source: [String: Any], _ key: String, path: String? = nil) throws -> Double {
        guard let value = source[key] as? NSNumber, value.doubleValue.isFinite else { throw missing(path ?? key) }
        return value.doubleValue
    }

    private static func integer(_ source: [String: Any], _ key: String, in range: ClosedRange<Int>) throws -> Int {
        try integer(try number(source, key), key, in: range)
    }

    /// Parses the package's `config.json` (snake_case keys, as upstream ships it) and range-checks every
    /// value the pipeline computes with, so a malformed config refuses at `prepare` instead of trapping or
    /// allocating absurd buffers later.
    public static func parse(_ data: Data) throws -> ArticulinoConfig {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "pipeline config malformed: not valid JSON")
        }
        guard let root = parsed as? [String: Any] else {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "pipeline config malformed: not an object")
        }
        guard let post = root["postprocess"] as? [String: Any] else { throw missing("postprocess") }
        guard let rawLanguages = root["languages"] as? [String: Any] else { throw missing("languages") }
        var languages: [String: Int] = [:]
        for (language, id) in rawLanguages {
            guard let id = id as? NSNumber, id.doubleValue.isFinite else { throw missing("languages.\(language)") }
            languages[language] = try integer(id.doubleValue, "languages.\(language)", in: 0 ... 65535)
        }
        guard let times = (root["times"] as? [Any])?.map({ ($0 as? NSNumber)?.floatValue }),
              !times.isEmpty, !times.contains(where: { $0 == nil })
        else { throw missing("times") }
        for (k, t) in times.compactMap({ $0 }).enumerated() where !(t >= 0 && t < 1) {
            throw malformed("times[\(k)] must be in [0, 1)")
        }
        guard let charset = root["charset"] as? String, !charset.isEmpty else { throw missing("charset") }
        let sampleRate = try integer(root, "sample_rate", in: 8000 ... 192_000)
        let latentDim = try integer(root, "latent_dim", in: 1 ... 4096)
        let samplesPerFrame = try integer(root, "samples_per_frame", in: 1 ... 65536)
        let durationUnitsPerFrame = try integer(root, "duration_units_per_frame", in: 1 ... 1000)
        let prefixFrames = try integer(root, "prefix_frames", in: 0 ... 100_000)
        let decoderLeadInFrames = try integer(root, "decoder_lead_in_frames", in: 0 ... 100_000)
        let maxDurationUnits = try number(root, "max_duration_units")
        guard maxDurationUnits > 0, maxDurationUnits <= maxDurationUnitsCap else {
            throw malformed("max_duration_units must be greater than 0 and at most \(Int(maxDurationUnitsCap))")
        }
        let lowShelfDb = try number(post, "low_shelf_db", path: "postprocess.low_shelf_db")
        let lowShelfHz = try number(post, "low_shelf_hz", path: "postprocess.low_shelf_hz")
        let shelfSlope = try number(post, "shelf_slope", path: "postprocess.shelf_slope")
        let peak = try number(post, "peak", path: "postprocess.peak")
        guard peak > 0, peak <= 1 else { throw malformed("postprocess.peak must be in (0, 1]") }
        guard shelfSlope > 0 else { throw malformed("postprocess.shelf_slope must be greater than 0") }
        return ArticulinoConfig(
            sampleRate: sampleRate,
            latentDim: latentDim,
            samplesPerFrame: samplesPerFrame,
            durationUnitsPerFrame: durationUnitsPerFrame,
            prefixFrames: prefixFrames,
            decoderLeadInFrames: decoderLeadInFrames,
            maxDurationUnits: Float(maxDurationUnits),
            times: times.compactMap { $0 },
            charset: charset,
            languages: languages,
            lowShelfDb: lowShelfDb,
            lowShelfHz: lowShelfHz,
            shelfSlope: shelfSlope,
            peak: peak
        )
    }
}
