import Foundation
import XCTest
@testable import IndeRunNeuralSpeech

final class ArticulinoMathTests: XCTestCase {
    private let charset = " abcdefghijklmnopqrstuvwxyzäöüß.,?!-'\":;()0123456789"

    private func config(charset: String? = nil) throws -> ArticulinoConfig {
        let json: [String: Any] = [
            "sample_rate": 24000, "latent_dim": 2, "samples_per_frame": 4, "duration_units_per_frame": 4,
            "prefix_frames": 2, "decoder_lead_in_frames": 1, "max_duration_units": 400.0,
            "times": [0.0, 0.25, 0.5, 0.75], "charset": charset ?? self.charset, "languages": ["de": 0, "en": 1],
            "postprocess": ["low_shelf_db": 2.0, "low_shelf_hz": 180.0, "shelf_slope": 0.7, "peak": 0.95]
        ]
        return try ArticulinoConfig.parse(JSONSerialization.data(withJSONObject: json))
    }

    func testNormalizeFoldsAccentsMapsTypographyAndDropsUnknownCodePoints() {
        XCTAssertEqual(ArticulinoMath.normalizeLetters("Café – „Zitat“ … ø 😀", charset: charset), "cafe - \"zitat\" . ö")
    }

    func testNormalizeCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(ArticulinoMath.normalizeLetters("  a \t\n b  ", charset: charset), "a b")
    }

    func testEncodeLettersMapsToOnePlusCharsetIndexWithOneLanguagePerLetter() throws {
        let cfg = try config()
        let de = ArticulinoMath.encodeLetters("Ich habe Hunger.", language: 0, config: cfg)
        XCTAssertEqual(Array(de.ids.prefix(4)), [10, 4, 9, 1])
        XCTAssertEqual(de.languages, Array(repeating: 0, count: de.ids.count))
        XCTAssertEqual(ArticulinoMath.encodeLetters("Hi", language: 1, config: cfg).languages, [1, 1])
        XCTAssertEqual(ArticulinoMath.encodeLetters("123 😀", language: 0, config: try config(charset: " abc")).ids, [])
    }

    func testIsLetterCountsLettersAndDigitsNotPlaceholderSpaceOrPunctuation() throws {
        let ids = ArticulinoMath.encodeLetters("a 1.", language: 0, config: try config()).ids
        XCTAssertEqual(([0] + ids).map { ArticulinoMath.isLetter($0, charset: charset) }, [false, true, false, true, false])
    }

    func testClampDurationsClampsMasksAndDividesBySpeed() {
        let logDurations = [5, 1000, 2].map { Float(Foundation.log(Double($0))) }
        let d = ArticulinoMath.clampDurations(logDurations: logDurations, mask: [0, 1, 1], speed: 2, maxUnits: 400)
        for (actual, expected) in zip(d, [0, 200, 1] as [Float]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
    }

    func testEqualizeLetterRateRescalesOnlyTheLettersToTheTargetRate() {
        var d: [Float] = [0, 10, 7, 10, 10]
        ArticulinoMath.equalizeLetterRate(&d, ids: [0, 2, 1, 3, 4], charset: charset, start: 1, target: 20)
        XCTAssertEqual(d[0], 0)
        XCTAssertEqual(d[2], 7)
        XCTAssertEqual(3 / ((d[1] + d[3] + d[4]) / 100), 20, accuracy: 1e-3)
    }

    func testEqualizeLetterRateLeavesDurationsAloneWithoutLetters() {
        var d: [Float] = [1]
        ArticulinoMath.equalizeLetterRate(&d, ids: [1], charset: charset, start: 0, target: 20)
        XCTAssertEqual(d, [1])
    }

    func testToInt16RoundsAndClips() {
        XCTAssertEqual(ArticulinoMath.toInt16([0, 0.5, 1.5, -2, -1]), [0, 16384, 32767, -32767, -32767])
    }

    func testSplitsAfterTheLastCommaBetweenTheLimits() {
        let text = String(repeating: "a", count: 119) + ", " + String(repeating: "b", count: 79)
        XCTAssertEqual(
            ArticulinoMath.splitLongSentence(text),
            [String(repeating: "a", count: 119) + ",", String(repeating: "b", count: 79)]
        )
    }

    func testKeepsShortTextWholeAndFallsBackToASpace() {
        XCTAssertEqual(ArticulinoMath.splitLongSentence("kurz."), ["kurz."])
        XCTAssertEqual(
            ArticulinoMath.splitLongSentence(String(repeating: "a", count: 100) + " " + String(repeating: "b", count: 99)),
            [String(repeating: "a", count: 100), String(repeating: "b", count: 99)]
        )
    }

    func testKeepsARunWithoutAnySeparatorWhole() {
        let run = String(repeating: "x", count: 300)
        XCTAssertEqual(ArticulinoMath.splitLongSentence(run), [run])
    }

    func testLowShelfIsUnityAtDcForZeroGainAndLimitPeakScalesDown() {
        let c = ArticulinoMath.lowShelfCoefficients(f0: 180, db: 0, sampleRate: 24000, slope: 0.7)
        XCTAssertEqual(c.b0, 1, accuracy: 1e-12)
        var loud: [Float] = [2, -2]
        ArticulinoMath.limitPeak(&loud, peak: 0.95)
        XCTAssertEqual(loud[0], 0.95, accuracy: 1e-6)
    }
}
