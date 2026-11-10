import Foundation
import XCTest
import IndeRunCore

/// The WAV vector of `packages/inderun-web/src/providers/neural-speech/wav.test.ts`, against the
/// Core encoder both Apple speech providers write their artifacts with.
final class SpeechWAVTests: XCTestCase {
    func testEncodesACanonicalMono16BitHeaderFollowedByLittleEndianSamples() {
        // Samples 0, 1, -1 as 16-bit little-endian PCM.
        let samples = Data([0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF])

        let wav = SpeechWAV.encode(samples: samples, sampleRate: 24000)

        XCTAssertEqual(SpeechWAV.headerBytes, 44)
        XCTAssertEqual(wav.count, 50)
        XCTAssertEqual(Array(wav), [
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x2A, 0x00, 0x00, 0x00, // 36 + data bytes = 42
            0x57, 0x41, 0x56, 0x45, // "WAVE"
            0x66, 0x6D, 0x74, 0x20, // "fmt "
            0x10, 0x00, 0x00, 0x00, // fmt chunk size 16
            0x01, 0x00, // PCM
            0x01, 0x00, // mono
            0xC0, 0x5D, 0x00, 0x00, // 24000 Hz
            0x80, 0xBB, 0x00, 0x00, // byte rate 48000
            0x02, 0x00, // block align
            0x10, 0x00, // 16 bits per sample
            0x64, 0x61, 0x74, 0x61, // "data"
            0x06, 0x00, 0x00, 0x00, // data bytes
            0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF
        ])
    }
}
