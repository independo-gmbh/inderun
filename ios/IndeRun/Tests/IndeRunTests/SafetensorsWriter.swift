import Foundation
import IndeRunNeuralSpeech

/// Test-side safetensors writer (F32 and I64 only); production code only reads the format.
func encodeSafetensors(_ tensors: [(name: String, tensor: SpeechTensor)], metadata: [String: String] = [:]) throws -> Data {
    var header: [String: Any] = ["__metadata__": metadata]
    var body: [Data] = []
    var offset = 0
    for (name, tensor) in tensors {
        var bytes = Data()
        let dtype: String
        switch tensor.data {
        case let .f32(values):
            dtype = "F32"
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        case let .i64(values):
            dtype = "I64"
            for value in values {
                withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        header[name] = ["dtype": dtype, "shape": tensor.shape, "data_offsets": [offset, offset + bytes.count]]
        body.append(bytes)
        offset += bytes.count
    }
    let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    return assembleSafetensors(header: json, body: body)
}

/// Frames an arbitrary header and body: the 8-byte little-endian header length comes first.
func assembleSafetensors(header: Data, body: [Data]) -> Data {
    var out = Data()
    withUnsafeBytes(of: UInt64(header.count).littleEndian) { out.append(contentsOf: $0) }
    out.append(header)
    body.forEach { out.append($0) }
    return out
}
