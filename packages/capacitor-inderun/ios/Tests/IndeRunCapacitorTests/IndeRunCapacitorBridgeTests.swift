import XCTest
import Foundation
import IndeRunContracts
@testable import IndeRunCapacitorPlugin

final class IndeRunCapacitorBridgeTests: XCTestCase {

    // MARK: - CapacitorRunOptions decoding

    func testDecodesConfigureOptionsWithOpenAI() throws {
        let json: [String: Any] = [
            "openAI": [
                "model": "gpt-5.2",
                "endpointURL": "/api/inderun/openai-responses",
                "auth": "none",
                "authContextRef": "openai/main",
                "timeoutMs": 30_000
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let options = try JSONDecoder().decode(CapacitorRunOptions.self, from: data)

        XCTAssertEqual(options.openAI?.model, "gpt-5.2")
        XCTAssertEqual(options.openAI?.endpointURL, "/api/inderun/openai-responses")
        XCTAssertEqual(options.openAI?.auth, "none")
        XCTAssertEqual(options.openAI?.authContextRef, "openai/main")
        XCTAssertEqual(options.openAI?.timeoutMs, 30_000)
        XCTAssertNil(options.allowDirectOpenAIEndpoint)
    }

    func testDecodesConfigureOptionsWithAllOptionalFieldsAbsent() throws {
        let data = try JSONSerialization.data(withJSONObject: [String: Any]())
        let options = try JSONDecoder().decode(CapacitorRunOptions.self, from: data)

        XCTAssertNil(options.openAI)
        XCTAssertNil(options.allowDirectOpenAIEndpoint)
    }

    func testDecodesOpenAIOptionsWithOnlyRequiredFields() throws {
        let json: [String: Any] = ["openAI": ["model": "gpt-4"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let options = try JSONDecoder().decode(CapacitorRunOptions.self, from: data)

        XCTAssertEqual(options.openAI?.model, "gpt-4")
        XCTAssertNil(options.openAI?.endpointURL)
        XCTAssertNil(options.openAI?.auth)
        XCTAssertNil(options.openAI?.authContextRef)
        XCTAssertNil(options.openAI?.timeoutMs)
    }

    func testDecodesAllowDirectOpenAIEndpoint() throws {
        let json: [String: Any] = ["allowDirectOpenAIEndpoint": true]
        let data = try JSONSerialization.data(withJSONObject: json)
        let options = try JSONDecoder().decode(CapacitorRunOptions.self, from: data)

        XCTAssertEqual(options.allowDirectOpenAIEndpoint, true)
    }

    // MARK: - encode(error:)

    func testEncodesIndeRunErrorRequiredFieldsOnly() throws {
        let bridge = IndeRunCapacitorBridge()
        let error = IndeRunError(
            details: nil,
            errorClass: .Unavailable,
            message: "Not configured.",
            providerId: nil,
            retryable: nil,
            retryAfterMs: nil,
            runId: nil,
            schemaVersion: .the10
        )

        let encoded = try bridge.encode(error: error)

        XCTAssertEqual(encoded["schemaVersion"] as? String, "1.0")
        XCTAssertEqual(encoded["errorClass"] as? String, "Unavailable")
        XCTAssertEqual(encoded["message"] as? String, "Not configured.")
        XCTAssertNil(encoded["providerId"])
        XCTAssertNil(encoded["retryable"])
        XCTAssertNil(encoded["retryAfterMs"])
        XCTAssertNil(encoded["runId"])
    }

    func testEncodesIndeRunErrorWithAllOptionalFields() throws {
        let bridge = IndeRunCapacitorBridge()
        let error = IndeRunError(
            details: nil,
            errorClass: .RateLimited,
            message: "Too many requests.",
            providerId: "openai",
            retryable: true,
            retryAfterMs: 2_000,
            runId: "run_abc",
            schemaVersion: .the10
        )

        let encoded = try bridge.encode(error: error)

        XCTAssertEqual(encoded["errorClass"] as? String, "RateLimited")
        XCTAssertEqual(encoded["providerId"] as? String, "openai")
        XCTAssertEqual(encoded["retryable"] as? Bool, true)
        XCTAssertEqual(encoded["retryAfterMs"] as? Int, 2_000)
        XCTAssertEqual(encoded["runId"] as? String, "run_abc")
    }

    // MARK: - mapAuthMode

    func testMapAuthModeNoneString() {
        let bridge = IndeRunCapacitorBridge()
        XCTAssertEqual(bridge.mapAuthMode("none"), .none)
    }

    func testMapAuthModeUnknownStringDefaultsToAuthContextRef() {
        let bridge = IndeRunCapacitorBridge()
        XCTAssertEqual(bridge.mapAuthMode("some_future_value"), .authContextRef)
    }

    func testMapAuthModeNilDefaultsToAuthContextRef() {
        let bridge = IndeRunCapacitorBridge()
        XCTAssertEqual(bridge.mapAuthMode(nil), .authContextRef)
    }
}
