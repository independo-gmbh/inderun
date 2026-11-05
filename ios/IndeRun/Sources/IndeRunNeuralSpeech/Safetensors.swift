import Foundation

/// A parsed safetensors file: its tensors by name and the `__metadata__` string map.
public struct SafetensorsFile: Sendable {
    public let tensors: [String: SpeechTensor]
    public let metadata: [String: String]
}

/// Reader for the safetensors format: an 8-byte little-endian header length, the JSON header and
/// the byte buffer. Only `F32` and `I64` tensors are accepted; any other dtype is refused by name.
public enum Safetensors {
    private static func malformed(_ why: String) -> NeuralSpeechRuntimeError {
        NeuralSpeechRuntimeError(kind: .capability, message: "voice file malformed: \(why)")
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double >= 0, double < 9_007_199_254_740_992, double == double.rounded() else { return nil }
        return Int(double)
    }

    public static func parse(_ data: Data) throws -> SafetensorsFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw malformed("shorter than the 8-byte header length") }
        let headerLength = (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << (8 * UInt64($1)) }
        guard headerLength <= UInt64(bytes.count - 8) else { throw malformed("header length exceeds the file") }
        let bufferStart = 8 + Int(headerLength)

        let header: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(bytes[8 ..< bufferStart])) as? [String: Any] else {
                throw malformed("header is not an object")
            }
            header = parsed
        } catch let error as NeuralSpeechRuntimeError {
            throw error
        } catch {
            throw malformed("header is not valid JSON")
        }

        let bufferLength = bytes.count - bufferStart
        var tensors: [String: SpeechTensor] = [:]
        var metadata: [String: String] = [:]
        for (name, raw) in header {
            if name == "__metadata__" {
                for (key, value) in raw as? [String: Any] ?? [:] {
                    guard let text = value as? String else { throw malformed("metadata '\(key)' is not a string") }
                    metadata[key] = text
                }
                continue
            }
            let entry = raw as? [String: Any] ?? [:]
            let dtype = entry["dtype"] as? String
            guard dtype == "F32" || dtype == "I64" else {
                throw NeuralSpeechRuntimeError(
                    kind: .capability, message: "voice file unsupported: dtype \(dtype ?? "unknown") of '\(name)'"
                )
            }
            guard let shape = (entry["shape"] as? [Any])?.compactMap(integer), shape.count == (entry["shape"] as? [Any])?.count,
                  let offsets = (entry["data_offsets"] as? [Any])?.compactMap(integer), offsets.count == 2,
                  (entry["data_offsets"] as? [Any])?.count == 2
            else { throw malformed("'\(name)' has an invalid shape or data_offsets") }
            let (begin, end) = (offsets[0], offsets[1])
            guard begin <= end, end <= bufferLength else { throw malformed("'\(name)' offsets lie outside the buffer") }
            let width = dtype == "F32" ? 4 : 8
            let count = try shape.reduce(1) { product, dimension in
                let (next, overflow) = product.multipliedReportingOverflow(by: dimension)
                if overflow { throw malformed("'\(name)' has an invalid shape or data_offsets") }
                return next
            }
            guard count <= Int.max / width, end - begin == count * width else {
                throw malformed("'\(name)' byte range does not match its shape")
            }
            let at = bufferStart + begin
            let word = { (index: Int) -> UInt64 in
                (0 ..< width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + index * width + $1]) << (8 * UInt64($1)) }
            }
            if dtype == "F32" {
                tensors[name] = SpeechTensor(shape: shape, data: .f32((0 ..< count).map { Float(bitPattern: UInt32(word($0))) }))
            } else {
                tensors[name] = SpeechTensor(shape: shape, data: .i64((0 ..< count).map { Int64(bitPattern: word($0)) }))
            }
        }
        return SafetensorsFile(tensors: tensors, metadata: metadata)
    }
}
