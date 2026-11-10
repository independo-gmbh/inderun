import Foundation

/// A canonical 44-byte RIFF/WAVE header (PCM, mono, 16-bit) followed by the samples: the
/// `audio/wav` artifact every Apple speech provider writes.
public enum SpeechWAV {
    /// Size of the header ``encode(samples:sampleRate:)`` writes ahead of the samples.
    public static let headerBytes = 44

    /// Encodes mono signed 16-bit little-endian PCM as a WAV file.
    /// - Parameters:
    ///   - samples: The PCM bytes, two per frame, little-endian.
    ///   - sampleRate: Frames per second.
    public static func encode(samples: Data, sampleRate: Int) -> Data {
        var data = Data(capacity: headerBytes + samples.count)
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + samples.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2)) // byte rate
        append16(2) // block align
        append16(16) // bits per sample
        append("data")
        append32(UInt32(samples.count))
        data.append(samples)
        return data
    }
}
