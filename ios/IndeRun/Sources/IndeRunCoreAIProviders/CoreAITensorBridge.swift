#if canImport(CoreAI)
import CoreAI
import Foundation

/// Copies a ``SpeechTensor`` into a newly allocated, C-contiguous `NDArray` (caller memory is never
/// shared with Core AI). Throws (internal) when the shape does not match the number of values.
@available(iOS 27, macOS 27, *)
func makeNDArray(_ tensor: SpeechTensor) throws -> NDArray {
    let count: Int
    switch tensor.data {
    case let .f32(values): count = values.count
    case let .i64(values): count = values.count
    }
    guard elementCount(tensor.shape) == count else {
        throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "tensor shape \(tensor.shape) does not match \(count) values")
    }
    // `NDArray(scalars:shape:)` traps on an empty sequence; an empty array needs no values.
    switch tensor.data {
    case let .f32(values):
        return values.isEmpty ? NDArray(shape: tensor.shape, scalarType: .float32) : NDArray(scalars: values, shape: tensor.shape)
    case let .i64(values):
        return values.isEmpty ? NDArray(shape: tensor.shape, scalarType: .int64) : NDArray(scalars: values, shape: tensor.shape)
    }
}

/// Copies an output `NDArray` into a ``SpeechTensor`` in logical (row-major) order, honouring its
/// strides (in elements), so a non-contiguous layout never reaches the pipeline reordered. Scalar
/// types other than float32 and int64, negative strides and interleaved layouts throw
/// `graph output unsupported: <role>.<name>` (internal) rather than produce wrong audio.
@available(iOS 27, macOS 27, *)
func makeSpeechTensor(_ array: NDArray, role: String, name: String) throws -> SpeechTensor {
    let unsupported = NeuralSpeechRuntimeError(kind: .internalFailure, message: "graph output unsupported: \(role).\(name)")
    let shape = array.shape
    let strides = array.strides
    let count = try checkOutputLayout(shape: shape, strides: strides, interleaved: array.interleaveLayout != nil, role: role, name: name)
    // A view of an empty array traps on its start index, so an empty output is not read at all.
    switch array.scalarType {
    case .float32 where count == 0:
        return SpeechTensor(shape: shape, data: .f32([]))
    case .int64 where count == 0:
        return SpeechTensor(shape: shape, data: .i64([]))
    case .float32:
        let values = array.view(as: Float.self).withUnsafePointer { pointer, _, _ in
            copyElements(pointer, shape: shape, strides: strides)
        }
        return SpeechTensor(shape: shape, data: .f32(values))
    case .int64:
        let values = array.view(as: Int64.self).withUnsafePointer { pointer, _, _ in
            copyElements(pointer, shape: shape, strides: strides)
        }
        return SpeechTensor(shape: shape, data: .i64(values))
    default:
        throw unsupported
    }
}

/// The element count of an output layout ``makeSpeechTensor(_:role:name:)`` can copy; throws
/// `graph output unsupported: <role>.<name>` (internal) for an interleaved layout, a stride per dimension
/// missing, a negative dimension or stride (the SDK does not document where a view's pointer sits for
/// negative strides; `NDArray`'s own initializers refuse them), or an overflowing element count.
func checkOutputLayout(shape: [Int], strides: [Int], interleaved: Bool, role: String, name: String) throws -> Int {
    guard !interleaved, strides.count == shape.count, strides.allSatisfy({ $0 >= 0 }), let count = elementCount(shape) else {
        throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "graph output unsupported: \(role).\(name)")
    }
    return count
}

/// The element count of `shape`, or `nil` for a negative dimension or an overflowing product.
private func elementCount(_ shape: [Int]) -> Int? {
    var count = 1
    for dimension in shape {
        guard dimension >= 0 else { return nil }
        let (product, overflow) = count.multipliedReportingOverflow(by: dimension)
        guard !overflow else { return nil }
        count = product
    }
    return count
}

/// Gathers the elements at `pointer` (non-negative strides in elements, possibly non-contiguous) in row-major order.
private func copyElements<T>(_ pointer: UnsafePointer<T>, shape: [Int], strides: [Int]) -> [T] {
    let count = elementCount(shape) ?? 0
    var contiguous = true
    var expected = 1
    for axis in shape.indices.reversed() where shape[axis] > 1 {
        if strides[axis] != expected { contiguous = false }
        expected *= shape[axis]
    }
    if contiguous {
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
    var result: [T] = []
    result.reserveCapacity(count)
    var index = [Int](repeating: 0, count: shape.count)
    var offset = 0
    for _ in 0 ..< count {
        result.append(pointer[offset])
        // Advance the multi-index, last axis fastest.
        var axis = shape.count - 1
        while axis >= 0 {
            index[axis] += 1
            offset += strides[axis]
            if index[axis] < shape[axis] { break }
            offset -= strides[axis] * index[axis]
            index[axis] = 0
            axis -= 1
        }
    }
    return result
}
#endif
