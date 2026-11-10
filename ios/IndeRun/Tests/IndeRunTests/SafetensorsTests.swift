import Foundation
import XCTest
@testable import IndeRunNeuralSpeech

final class SafetensorsTests: XCTestCase {
    private func failure(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> NeuralSpeechRuntimeError? {
        do {
            _ = try Safetensors.parse(data)
        } catch let error as NeuralSpeechRuntimeError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        XCTFail("expected parse to throw", file: file, line: line)
        return nil
    }

    private func header(_ json: String) -> Data { Data(json.utf8) }

    func testRoundTripsF32AndI64TensorsAndMetadata() throws {
        let bytes = try encodeSafetensors(
            [
                ("a", SpeechTensor(shape: [2, 3], data: .f32([1, 2, 3, 4, 5, -6.5]))),
                ("b", SpeechTensor(shape: [2], data: .i64([7, -8])))
            ],
            metadata: ["format": "test/1"]
        )
        let file = try Safetensors.parse(bytes)
        XCTAssertEqual(file.metadata, ["format": "test/1"])
        XCTAssertEqual(file.tensors["a"], SpeechTensor(shape: [2, 3], data: .f32([1, 2, 3, 4, 5, -6.5])))
        XCTAssertEqual(file.tensors["b"], SpeechTensor(shape: [2], data: .i64([7, -8])))
    }

    func testRefusesADtypeOtherThanF32AndI64ByName() {
        let bytes = assembleSafetensors(
            header: header(#"{"w":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#), body: [Data(count: 2)]
        )
        let error = failure(bytes)
        XCTAssertEqual(error?.kind, .capability)
        XCTAssertEqual(error?.message, "voice file unsupported: dtype F16 of 'w'")
    }

    func testRefusesOffsetsBeyondTheBuffer() {
        let bytes = assembleSafetensors(
            header: header(#"{"w":{"dtype":"F32","shape":[2],"data_offsets":[0,8]}}"#), body: [Data(count: 4)]
        )
        let error = failure(bytes)
        XCTAssertEqual(error?.kind, .capability)
        XCTAssertTrue(error?.message.hasPrefix("voice file malformed: ") == true)
    }

    func testRefusesAByteRangeThatDoesNotMatchTheShape() {
        let bytes = assembleSafetensors(
            header: header(#"{"w":{"dtype":"F32","shape":[3],"data_offsets":[0,8]}}"#), body: [Data(count: 8)]
        )
        XCTAssertTrue(failure(bytes)?.message.hasPrefix("voice file malformed: ") == true)
    }

    func testRefusesATruncatedOrOversizedOrNonJsonHeader() {
        XCTAssertTrue(failure(Data(count: 4))?.message.hasPrefix("voice file malformed: ") == true)
        var oversized = Data()
        withUnsafeBytes(of: UInt64(1000).littleEndian) { oversized.append(contentsOf: $0) }
        oversized.append(Data(count: 8))
        XCTAssertTrue(failure(oversized)?.message.hasPrefix("voice file malformed: ") == true)
        XCTAssertTrue(failure(assembleSafetensors(header: header("not json"), body: []))?.message.hasPrefix("voice file malformed: ") == true)
    }
}
