import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// A provider that declares only `text_to_speech`, with managed playback. Its id sorts
/// first, so only its declarations can keep it out of a text route.
private final class SpeechOnlyProvider: ProviderAdapter, @unchecked Sendable {
    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: "a_speech_only",
            type: .local,
            transport: .systemService,
            supports: ProviderSupports(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .hard,
            tasks: ["text_to_speech"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_speech",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(run: true, stream: false),
                    cancel: .hard,
                    outputs: [ProviderTaskOutput(delivery: .playback)]
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [
                ProviderTaskAvailability(kind: "text_to_speech", voices: [ProviderVoice(locale: "de-DE")])
            ]
        )
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        XCTFail("A text request must never reach a speech-only provider")
        throw createInternal(message: "unreachable")
    }
}

/// Declares `text_to_text` explicitly but accepts only image input. Its id sorts first.
private final class ImageOnlyTextProvider: ProviderAdapter, @unchecked Sendable {
    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: "a_image_only",
            type: .local,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: true
            ),
            cancel: .soft,
            tasks: ["text_to_text"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_text",
                    inputs: [.image],
                    interaction: ProviderTaskInteraction(run: true, stream: false),
                    cancel: .soft,
                    outputs: [ProviderTaskOutput(delivery: .inline)]
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        XCTFail("A text prompt must never reach a provider that only accepts images")
        throw createInternal(message: "unreachable")
    }
}

/// Per-task provider capabilities through the real Rust planner (#243). The planner
/// semantics are pinned by the shared vectors in `contracts/fixtures/routing/`; these
/// tests check that the Swift engine hands the planner the per-task declarations and
/// surfaces them.
final class TaskCapabilityRoutingTests: XCTestCase {
    private var registry: ProviderRegistry!
    private var inderun: IndeRun!

    override func setUp() {
        super.setUp()
        registry = ProviderRegistry()
        inderun = IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
    }

    func testTextRequestIsNeverRoutedToASpeechOnlyProvider() async throws {
        try registry.register(SpeechOnlyProvider())
        try registry.register(MockProvider(id: "z_text", type: .local))

        let result = try await inderun.run(request: TaskRequest(prompt: "Hello"))

        XCTAssertEqual(result.telemetry.providerUsed, "z_text")
        let rejection = result.provenance?.routeRejections.first { $0.providerId == "a_speech_only" }
        XCTAssertEqual(rejection?.codes, [.taskNotSupported])
    }

    func testTextRequestSendsTextInputSoAnImageOnlyProviderIsRejected() async throws {
        try registry.register(ImageOnlyTextProvider())
        try registry.register(MockProvider(id: "z_text", type: .local))

        let result = try await inderun.run(request: TaskRequest(prompt: "Hello"))

        XCTAssertEqual(result.telemetry.providerUsed, "z_text")
        let rejection = result.provenance?.routeRejections.first { $0.providerId == "a_image_only" }
        XCTAssertEqual(rejection?.codes, [.inputNotSupported])
    }

    func testTextRequestFailsWithTaskNotSupportedWhenOnlySpeechIsRegistered() async throws {
        try registry.register(SpeechOnlyProvider())

        do {
            _ = try await inderun.run(request: TaskRequest(prompt: "Hello"))
            XCTFail("Expected a routing refusal")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
            let rejected = try XCTUnwrap(error.details?["rejectedProviders"]?.value as? [[String: Any]])
            let codes = (rejected.first?["reasons"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
            XCTAssertEqual(codes, ["task_not_supported"])
        }
    }

    func testCheckCapabilitiesReportsTaskCapabilities() async throws {
        try registry.register(SpeechOnlyProvider())

        let snapshots = await inderun.checkCapabilities()
        let snapshot = try XCTUnwrap(snapshots.first)

        XCTAssertEqual(snapshot.descriptor.taskCapabilities?.first?.kind, "text_to_speech")
        XCTAssertEqual(snapshot.descriptor.taskCapabilities?.first?.outputs.first?.delivery, .playback)
        XCTAssertEqual(snapshot.capabilities.taskCapabilities?.first?.voices?.first?.locale, "de-DE")
    }
}
