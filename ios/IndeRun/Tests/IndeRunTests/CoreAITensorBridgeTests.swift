import Foundation
import XCTest
#if canImport(CoreAI)
import CoreAI
#endif
@testable import IndeRunCoreAIProviders

final class CoreAITensorBridgeTests: XCTestCase {
    func testTensorsRoundTripThroughNDArray() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let f32 = SpeechTensor(shape: [1, 3], data: .f32([0.5, -1, 2.25]))
        XCTAssertEqual(try makeSpeechTensor(try makeNDArray(f32), role: "text", name: "x"), f32)
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testInt64InputsAreNarrowedToInt32() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let array = try makeNDArray(SpeechTensor(shape: [1, 4], data: .i64([0, 1, -2, 2_147_483_647])))
        XCTAssertEqual(array.scalarType, .int32)
        XCTAssertEqual(array.shape, [1, 4])
        let values = array.view(as: Int32.self).withUnsafePointer { pointer, _, _ in Array(UnsafeBufferPointer(start: pointer, count: 4)) }
        XCTAssertEqual(values, [0, 1, -2, 2_147_483_647])
        XCTAssertEqual(try makeNDArray(SpeechTensor(shape: [1, 0], data: .i64([]))).scalarType, .int32)
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testInt64OutsideInt32RangeThrows() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        for value: Int64 in [2_147_483_648, -2_147_483_649, Int64.max] {
            XCTAssertThrowsError(try makeNDArray(SpeechTensor(shape: [1, 2], data: .i64([1, value])))) { error in
                XCTAssertEqual((error as? NeuralSpeechRuntimeError)?.kind, .internalFailure)
                XCTAssertEqual((error as? NeuralSpeechRuntimeError)?.message, "tensor value out of int32 range")
            }
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testAShapeThatDoesNotMatchTheValuesIsRefused() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        XCTAssertThrowsError(try makeNDArray(SpeechTensor(shape: [2, 3], data: .f32([1, 2])))) { error in
            XCTAssertEqual((error as? NeuralSpeechRuntimeError)?.kind, .internalFailure)
        }
        XCTAssertThrowsError(try makeNDArray(SpeechTensor(shape: [-1, 3], data: .i64([1, 2, 3]))))
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testANonContiguousArrayIsCopiedInLogicalOrder() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        // Column-major [2, 3]: element (i, j) sits at i * 1 + j * 2.
        var floats = NDArray(shape: [2, 3], scalarType: .float32, strides: [1, 2])
        floats.mutableRawView().withUnsafeMutableBytes { pointer, _, _ in
            let values = pointer.assumingMemoryBound(to: Float.self)
            for offset in 0 ..< 6 { values[offset] = Float(offset) }
        }
        XCTAssertEqual(try makeSpeechTensor(floats, role: "decoder", name: "waveform"), SpeechTensor(shape: [2, 3], data: .f32([0, 2, 4, 1, 3, 5])))

        var ints = NDArray(shape: [2, 2], scalarType: .int64, strides: [1, 2])
        ints.mutableRawView().withUnsafeMutableBytes { pointer, _, _ in
            let values = pointer.assumingMemoryBound(to: Int64.self)
            for offset in 0 ..< 4 { values[offset] = Int64(offset) * 10 }
        }
        XCTAssertEqual(try makeSpeechTensor(ints, role: "text", name: "ids"), SpeechTensor(shape: [2, 2], data: .i64([0, 20, 10, 30])))
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testSizeOneAxesAndRankZeroAreCopiedInLogicalOrder() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        func filled(_ shape: [Int], strides: [Int], count: Int) -> NDArray {
            var array = NDArray(shape: shape, scalarType: .float32, strides: strides)
            array.mutableRawView().withUnsafeMutableBytes { pointer, _, _ in
                let values = pointer.assumingMemoryBound(to: Float.self)
                for offset in 0 ..< count { values[offset] = Float(offset) }
            }
            return array
        }
        // Element (i, 0, j) sits at i * 1 + j * 3; the size-1 axis's stride is never stepped.
        XCTAssertEqual(
            try makeSpeechTensor(filled([3, 1, 2], strides: [1, 7, 3], count: 6), role: "decoder", name: "waveform"),
            SpeechTensor(shape: [3, 1, 2], data: .f32([0, 3, 1, 4, 2, 5]))
        )
        // An odd stride on a size-1 axis leaves a row-major layout contiguous.
        XCTAssertEqual(
            try makeSpeechTensor(filled([2, 1, 3], strides: [3, 5, 1], count: 6), role: "decoder", name: "waveform"),
            SpeechTensor(shape: [2, 1, 3], data: .f32([0, 1, 2, 3, 4, 5]))
        )
        let scalar = SpeechTensor(shape: [], data: .f32([42]))
        XCTAssertEqual(try makeSpeechTensor(try makeNDArray(scalar), role: "text", name: "count"), scalar)
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testAnOutputLayoutWithANegativeStrideIsUnsupported() throws {
        #if canImport(CoreAI)
        // `NDArray`'s initializers trap on a negative stride, so the layout check is tested directly.
        XCTAssertEqual(try checkOutputLayout(shape: [2, 3], strides: [1, 2], interleaved: false, role: "decoder", name: "waveform"), 6)
        for (strides, interleaved) in [([-3, 1], false), ([3, -1], false), ([3], false), ([3, 1], true)] {
            XCTAssertThrowsError(
                try checkOutputLayout(shape: [2, 3], strides: strides, interleaved: interleaved, role: "decoder", name: "waveform")
            ) { error in
                let error = error as? NeuralSpeechRuntimeError
                XCTAssertEqual(error?.kind, .internalFailure)
                XCTAssertEqual(error?.message, "graph output unsupported: decoder.waveform")
            }
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testAnEmptyArrayBecomesAnEmptyTensor() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let empty = SpeechTensor(shape: [1, 0], data: .f32([]))
        XCTAssertEqual(try makeSpeechTensor(try makeNDArray(empty), role: "text", name: "x"), empty)
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }

    func testABoolOutputIsUnsupported() throws {
        #if canImport(CoreAI)
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip(CoreAISupport.unavailableReason) }
        let mask = NDArray(shape: [1, 2], scalarType: .bool)
        XCTAssertThrowsError(try makeSpeechTensor(mask, role: "text", name: "text_mask")) { error in
            let error = error as? NeuralSpeechRuntimeError
            XCTAssertEqual(error?.kind, .internalFailure)
            XCTAssertEqual(error?.message, "graph output unsupported: text.text_mask")
        }
        #else
        throw XCTSkip(CoreAISupport.unavailableReason)
        #endif
    }
}
