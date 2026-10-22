import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore

/// A third, non-audio output through the unchanged output check (#245). Swift cannot build a
/// request for a task kind the schemas do not define, so the full engine pass-through of a fake
/// image task lives in the Web suite (`engine.third-task.test.ts`) and the planner side in the
/// shared `planner-conformance.json`; this pins that the check itself is delivery-based and
/// carries no audio assumption.
final class ThirdTaskOutputTests: XCTestCase {
    private func artifactRequest(accepting mediaTypes: [String]) -> TaskRequest {
        TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            speech: SpeechInput(locale: "de-AT", localeMatch: nil, text: "Hallo", voice: nil),
            delivery: OutputDeliveryRequest(mediaTypes: mediaTypes, mode: .artifact)
        )
    }

    private func image(_ mediaType: String) -> TaskOutput {
        TaskOutput(
            artifact: MediaArtifact(
                byteLength: 8,
                durationMs: nil,
                id: "art_image",
                lifetime: .untilDisposed,
                mediaType: mediaType,
                owner: .engine
            )
        )
    }

    func testAnImageArtifactPassesTheArtifactCheck() {
        let request = artifactRequest(accepting: ["image/png"])
        XCTAssertNil(checkOutput(request: request, delivery: .artifact, output: image("image/png"), providerId: "p"))
    }

    func testAnImageOfAnotherMediaTypeIsAMismatch() {
        let request = artifactRequest(accepting: ["image/png"])
        let error = checkOutput(request: request, delivery: .artifact, output: image("image/jpeg"), providerId: "p")
        XCTAssertEqual(error?.errorClass, .Internal)
        XCTAssertEqual(error?.details?["code"]?.value as? String, "output_mismatch")
    }

    func testAnImageArtifactNeverSatisfiesPlayback() {
        let request = artifactRequest(accepting: ["image/png"])
        XCTAssertNotNil(checkOutput(request: request, delivery: .playback, output: image("image/png"), providerId: "p"))
    }
}
