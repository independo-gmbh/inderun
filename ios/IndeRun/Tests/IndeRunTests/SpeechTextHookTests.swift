import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech
@testable import IndeRunOnnxProviders
@testable import IndeRunCoreAIProviders

/// The shipped `normalizeText` hooks: only Articulino's grapheme frontend reaches the shared core,
/// and the composed runtimes forward only for the `articulino` pipeline.
final class SpeechTextHookTests: XCTestCase {
    private let input = "Am 3. Mai."
    private let spoken = "Am dritten Mai."

    private func makePackage(pipeline: String = "articulino", kind: String = "grapheme") throws -> ModelPackage {
        let json = """
        {"id":"p","version":"1","format":"onnx","tasks":["text_to_speech"],"source":{"sourceType":"app_managed"},
         "speech":{"pipeline":"\(pipeline)","sampleRate":24000,"graphs":{"text":"text.onnx"},
          "frontend":{"kind":"\(kind)"},"voices":[{"id":"v","name":"V","locales":["de-DE"]}]}}
        """
        return try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
    }

    func testTheSharedBindingNormalizesGerman() {
        XCTAssertEqual(SharedCoreSpeechText.normalize(input, locale: "de-DE"), spoken)
        XCTAssertEqual(SharedCoreSpeechText.normalize(input, locale: "en-US"), input)
    }

    func testArticulinoNormalizesAGraphemeFrontend() throws {
        XCTAssertEqual(ArticulinoRuntime.normalizeText(try makePackage(), text: input, locale: "de-DE"), spoken)
    }

    func testArticulinoKeepsTheTextForAnyOtherFrontend() throws {
        XCTAssertEqual(ArticulinoRuntime.normalizeText(try makePackage(kind: "phoneme"), text: input, locale: "de-DE"), input)
    }

    func testTheOnnxRuntimeForwardsOnlyForArticulino() throws {
        let runtime = OnnxNeuralSpeechRuntime()
        XCTAssertEqual(runtime.normalizeText(try makePackage(), text: input, locale: "de-DE"), spoken)
        XCTAssertEqual(runtime.normalizeText(try makePackage(pipeline: "other"), text: input, locale: "de-DE"), input)
    }

    func testTheCoreAIRuntimeForwardsOnlyForArticulino() throws {
        let runtime = CoreAINeuralSpeechRuntime()
        XCTAssertEqual(runtime.normalizeText(try makePackage(), text: input, locale: "de-DE"), spoken)
        XCTAssertEqual(runtime.normalizeText(try makePackage(pipeline: "other"), text: input, locale: "de-DE"), input)
    }

    func testArticulinoReturnsTextThatIsNotGermanUnchangedEvenWithANulCharacter() throws {
        let text = "Hello\u{0000}World"
        for locale in ["en-US", "fr", "", "deu"] {
            XCTAssertEqual(ArticulinoRuntime.normalizeText(try makePackage(), text: text, locale: locale), text, locale)
        }
    }

    func testArticulinoMatchesTheGermanLanguageSubtagLikeTheCore() throws {
        for locale in ["de", "de-DE", "DE_at", "De-CH"] {
            XCTAssertEqual(ArticulinoRuntime.normalizeText(try makePackage(), text: input, locale: locale), spoken, locale)
        }
    }
}
