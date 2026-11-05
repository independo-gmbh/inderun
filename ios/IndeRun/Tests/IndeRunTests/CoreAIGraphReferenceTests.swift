import Foundation
import XCTest
@testable import IndeRunCoreAIProviders

final class CoreAIGraphReferenceTests: XCTestCase {
    func testAPlainFileNamesTheFunctionAfterTheRole() throws {
        let reference = try CoreAIGraphReference(role: "text", value: "articulino.aimodel")
        XCTAssertEqual(reference.file, "articulino.aimodel")
        XCTAssertEqual(reference.function, "text")
    }

    func testAFunctionSuffixNamesTheFunction() throws {
        let reference = try CoreAIGraphReference(role: "dit_step", value: "articulino.aimodel#dit")
        XCTAssertEqual(reference, try CoreAIGraphReference(role: "other", value: "articulino.aimodel#dit"))
        XCTAssertEqual(reference.file, "articulino.aimodel")
        XCTAssertEqual(reference.function, "dit")
    }

    func testInvalidFormsAreRefused() {
        for value in ["", "#text", "articulino.aimodel#", "a.aimodel#b#c", "#"] {
            XCTAssertThrowsError(try CoreAIGraphReference(role: "text", value: value), value) { error in
                let error = error as? NeuralSpeechRuntimeError
                XCTAssertEqual(error?.kind, .capability)
                XCTAssertEqual(error?.message, "graph reference invalid: text: \(value)")
            }
        }
    }

    func testSupportReasonText() {
        XCTAssertEqual(CoreAISupport.unavailableReason, "Core AI requires iOS 27 / macOS 27")
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            XCTAssertTrue(CoreAISupport.isAvailable)
        } else {
            XCTAssertFalse(CoreAISupport.isAvailable)
        }
        #else
        XCTAssertFalse(CoreAISupport.isAvailable)
        #endif
    }
}
