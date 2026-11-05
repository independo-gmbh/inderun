// Adapted from eigenhand/articulino-onnx, Apache License 2.0
// (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).
//
// The Articulino host math between the ONNX graphs: pure functions, no I/O, no model package. The
// behaviour is pinned by contracts/fixtures/speech/articulino-pipeline.json, generated from
// tools/neural-speech/articulino_math.py; Float (float32) rounding follows that reference, and
// only the biquad runs in Double.

import Foundation

/// Returns `count` standard-normal values.
public typealias NoiseSource = @Sendable (Int) -> [Float]

public enum ArticulinoMath {
    /// Box-Muller over the system random number generator; the default when a caller injects no noise.
    public static let gaussianNoise: NoiseSource = { count in
        var out = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            let u = 1 - Double.random(in: 0 ..< 1)
            let v = Double.random(in: 0 ..< 1)
            let radius = (-2 * Foundation.log(u)).squareRoot()
            out[i] = Float(radius * Foundation.cos(2 * Double.pi * v))
            if i + 1 < count { out[i + 1] = Float(radius * Foundation.sin(2 * Double.pi * v)) }
            i += 2
        }
        return out
    }

    private static let replacements: [Unicode.Scalar: String] = [
        "\u{2019}": "'", "\u{2018}": "'", "`": "'", "\u{00B4}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{00AB}": "\"", "\u{00BB}": "\"",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2026}": ".",
        "\u{00F8}": "\u{00F6}", "\u{00E6}": "\u{00E4}", "\u{00F0}": "d", "\u{00FE}": "th"
    ]
    private static let kept: Set<Unicode.Scalar> = ["\u{00E4}", "\u{00F6}", "\u{00FC}", "\u{00DF}"]
    private static let splitCharacters: Set<Unicode.Scalar> = [",", ";", ":", "-", " "]

    /// Lowercases, applies the replacement map, NFKD-decomposes code points outside the charset
    /// (dropping combining marks), drops what is still outside it, and collapses whitespace.
    static func normalizeLetters(_ text: String, charset: String) -> String {
        let allowed = Set(charset.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        func append(_ scalar: Unicode.Scalar) {
            if SpeechTextFrontend.isWhitespace(scalar) {
                pendingSpace = !out.isEmpty
            } else if allowed.contains(scalar) {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        for original in text.lowercased().unicodeScalars {
            let mapped = replacements[original] ?? String(original)
            let scalars = Array(mapped.unicodeScalars)
            if scalars.count == 1, !allowed.contains(scalars[0]), !kept.contains(scalars[0]) {
                for decomposed in mapped.decomposedStringWithCompatibilityMapping.unicodeScalars
                where decomposed.properties.generalCategory != .nonspacingMark {
                    append(decomposed)
                }
            } else {
                scalars.forEach(append)
            }
        }
        return String(out)
    }

    /// Letter ids (1 + charset index; 0 is the prompt placeholder) and the language id per letter.
    static func encodeLetters(_ text: String, language: Int, config: ArticulinoConfig) -> (ids: [Int], languages: [Int]) {
        var index: [Unicode.Scalar: Int] = [:]
        for (i, scalar) in config.charset.unicodeScalars.enumerated() where index[scalar] == nil { index[scalar] = i }
        let ids = normalizeLetters(text, charset: config.charset).unicodeScalars.compactMap { index[$0].map { $0 + 1 } }
        return (ids, ids.map { _ in language })
    }

    /// Letters and digits count for the speaking rate; the placeholder, spaces and punctuation do not.
    static func isLetter(_ id: Int, charset: String) -> Bool {
        isLetter(id, characters: Array(charset.unicodeScalars))
    }

    private static func isLetter(_ id: Int, characters: [Unicode.Scalar]) -> Bool {
        guard id > 0, id <= characters.count else { return false }
        let properties = characters[id - 1].properties
        return properties.isAlphabetic || properties.numericType != nil
    }

    /// Durations in 10 ms units: `min(exp(logDurations) * mask, maxUnits) / speed`. `mask` is the
    /// model's int64 text mask (0/1).
    static func clampDurations(logDurations: [Float], mask: [Int64], speed: Float, maxUnits: Float) -> [Float] {
        zip(logDurations, mask).map { log, keep in
            let scaled = Float(Foundation.exp(Double(log))) * Float(keep)
            return min(scaled, maxUnits) / speed
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Rescales, in place, the durations of the letters at index `start` onward (`ids` are the
    /// model's text ids, placeholder included) so they speak at exactly `target` letters per
    /// second. Single overlong letters count at most three times the median; nothing changes
    /// without letters.
    static func equalizeLetterRate(_ d: inout [Float], ids: [Int], charset: String, start: Int, target: Float) {
        let characters = Array(charset.unicodeScalars)
        let letters = ids.indices.filter { $0 >= start && isLetter(ids[$0], characters: characters) }
        guard !letters.isEmpty, target > 0 else { return }
        let floored = letters.map { max(d[$0], 0.5) }
        let cap = 3 * median(floored)
        let x = floored.map { min($0, cap) }
        let sum = Float(x.reduce(Double(0)) { $0 + Double($1) })
        let rate = Float(letters.count) / (sum / 100)
        let scale = rate / target
        for (k, index) in letters.enumerated() { d[index] = x[k] * scale }
    }

    /// Number of audio frames the durations span: `ceil(sum(d) / units)`, summed in float32. Saturates to
    /// `Int.max` for a sum no `Int` holds (or a non-finite one), so the conversion never traps; the
    /// pipeline refuses such a count before allocating.
    static func frameCount(_ d: [Float], units: Int) -> Int {
        var sum: Float = 0
        for value in d { sum += value }
        let frames = (Double(sum) / Double(units)).rounded(.up)
        guard frames.isFinite, abs(frames) < 9e18 else { return Int.max }
        return Int(frames)
    }

    // swiftlint:disable function_parameter_count
    /// Per new frame `j = first ..< frames`, the overlap-weighted sum of the letter features
    /// (flat, `stride` values per letter) over the frame's `units`-wide window.
    static func frameCondition(
        features: [Float], stride: Int, durations d: [Float], first: Int, frames: Int, units: Int
    ) -> [Float] {
        var end = [Float](repeating: 0, count: d.count)
        var running: Float = 0
        for (l, value) in d.enumerated() {
            running += value
            end[l] = running
        }
        let width = Float(units)
        var out = [Float](repeating: 0, count: max(0, frames - first) * stride)
        for j in first ..< max(first, frames) {
            let lo = Float(j) * width
            let hi = lo + width
            let row = (j - first) * stride
            for l in d.indices {
                let stop = end[l]
                let begin = stop - d[l]
                let w = max(min(stop, hi) - max(begin, lo), 0) / width
                if w == 0 { continue }
                for c in 0 ..< stride { out[row + c] += w * features[l * stride + c] }
            }
        }
        return out
    }

    // swiftlint:enable function_parameter_count

    /// One flow step: `x1 = x + (1 - t) * velocity`. With `nextT` and `nextNoise` it also returns
    /// the next input `(1 - nextT) * nextNoise + nextT * x1`.
    static func flowStep(
        x: [Float], t: Float, velocity: [Float], nextT: Float? = nil, nextNoise: [Float]? = nil
    ) -> (x1: [Float], next: [Float]?) {
        let scale = 1 - t
        let x1 = zip(x, velocity).map { $0 + scale * $1 }
        guard let nextT, let nextNoise else { return (x1, nil) }
        let keep = 1 - nextT
        return (x1, zip(nextNoise, x1).map { keep * $0 + nextT * $1 })
    }

    // swiftlint:disable large_tuple
    /// RBJ cookbook low shelf (z = -1), normalized by a0.
    static func lowShelfCoefficients(
        f0: Double, db: Double, sampleRate: Double, slope: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let a = Foundation.pow(10, db / 40)
        let w = 2 * Double.pi * f0 / sampleRate
        let c = Foundation.cos(w)
        let q = 2 * a.squareRoot() * (Foundation.sin(w) / 2) * ((a + 1 / a) * (1 / slope - 1) + 2).squareRoot()
        let z = -1.0
        let b0 = a * (a + 1 + z * (a - 1) * c + q)
        let b1 = -2 * z * a * (a - 1 + z * (a + 1) * c)
        let b2 = a * (a + 1 + z * (a - 1) * c - q)
        let a0 = a + 1 - z * (a - 1) * c + q
        let a1 = 2 * z * (a - 1 - z * (a + 1) * c)
        let a2 = a + 1 - z * (a - 1) * c - q
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// Direct form II transposed in Double over the whole signal.
    static func applyBiquad(_ samples: [Float], _ c: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)) -> [Float] {
        var z1 = 0.0
        var z2 = 0.0
        return samples.map { sample in
            let v = Double(sample)
            let o = c.b0 * v + z1
            z1 = c.b1 * v - c.a1 * o + z2
            z2 = c.b2 * v - c.a2 * o
            return Float(o)
        }
    }

    // swiftlint:enable large_tuple

    /// Scales `samples` in place so that no value exceeds `peak` in magnitude.
    static func limitPeak(_ samples: inout [Float], peak: Float) {
        let maximum = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maximum > peak else { return }
        let scale = peak / maximum
        for i in samples.indices { samples[i] *= scale }
    }

    /// Decoder waveform to speech: low shelf over the whole waveform (lead-in included), cut the
    /// lead-in, limit to the configured peak.
    static func shapeWaveform(_ waveform: [Float], leadSamples: Int, config: ArticulinoConfig) -> [Float] {
        let shelf = lowShelfCoefficients(
            f0: config.lowShelfHz, db: config.lowShelfDb, sampleRate: Double(config.sampleRate), slope: config.shelfSlope
        )
        var out = Array(applyBiquad(waveform, shelf).dropFirst(leadSamples))
        limitPeak(&out, peak: Float(config.peak))
        return out
    }

    /// `samples` followed by `pauseMs` of silence.
    static func padSilence(_ samples: [Float], pauseMs: Int, sampleRate: Int) -> [Float] {
        samples + [Float](repeating: 0, count: max(0, Int((Double(pauseMs) / 1000 * Double(sampleRate)).rounded())))
    }

    /// `round(clamp(x, -1, 1) * 32767)`, halves rounding up as `Math.round` does.
    static func toInt16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16((Double(min(1, max(-1, $0))) * 32767 + 0.5).rounded(.down)) }
    }

    /// Pieces of at most `maxLetters` code points where possible: cut at the last `, ; : -` (after
    /// the separator) or space between index `minSplit` and `maxLetters`. A run without any of
    /// them stays whole. Expects normalized text.
    static func splitLongSentence(_ text: String, maxLetters: Int = 180, minSplit: Int = 60) -> [String] {
        var pieces: [String] = []
        var rest = Array(text.unicodeScalars)
        while rest.count > maxLetters {
            guard let at = stride(from: min(maxLetters, rest.count) - 1, through: minSplit, by: -1)
                .first(where: { splitCharacters.contains(rest[$0]) })
            else { break }
            let cut = rest[at] == " " ? at : at + 1
            pieces.append(trimmed(rest[..<cut]))
            rest = Array(trimmed(rest[cut...]).unicodeScalars)
        }
        pieces.append(String(String.UnicodeScalarView(rest)))
        return pieces
    }

    private static func trimmed(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var slice = scalars
        while let first = slice.first, SpeechTextFrontend.isWhitespace(first) { slice.removeFirst() }
        while let last = slice.last, SpeechTextFrontend.isWhitespace(last) { slice.removeLast() }
        return String(String.UnicodeScalarView(slice))
    }
}
