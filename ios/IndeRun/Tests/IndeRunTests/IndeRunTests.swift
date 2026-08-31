import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunAppleProviders
@testable import IndeRunOpenAIProviders
@testable import IndeRunOnnxProviders
@testable import IndeRunSwift

// MARK: - Mocks for Testing

final class MockConnectivityService: ConnectivityService, @unchecked Sendable {
    var online: Bool = true
    func isOnline() async -> Bool { online }
}

final class MockClockService: ClockService, @unchecked Sendable {
    var currentTime: Int64 = 1000
    func now() -> Int64 {
        currentTime += 10
        return currentTime
    }
}

final class MockTelemetryService: TelemetryService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _events: [TelemetryEvent] = []
    
    var events: [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
    
    func emit(event: TelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

actor MockSecureStorageService: SecureStorageService {
    private var slots: [String: String]

    init(slots: [String: String] = [:]) {
        self.slots = slots
    }

    func getSecret(slotId: String) async -> String? {
        return slots[slotId]
    }

    func setSecret(slotId: String, secret: String) async {
        slots[slotId] = secret
    }

    func deleteSecret(slotId: String) async {
        slots.removeValue(forKey: slotId)
    }
}

actor MockHttpClientService: HttpClientService {
    private var requests: [HttpRequest] = []
    var responses: [Result<HttpResponse, Error>]

    init(responses: [Result<HttpResponse, Error>]) {
        self.responses = responses
    }

    func send(request: HttpRequest) async throws -> HttpResponse {
        requests.append(request)
        let response = responses.removeFirst()
        return try response.get()
    }

    func snapshotRequests() -> [HttpRequest] {
        requests
    }
}

struct TestCancellationError: Error {}

final class MockProvider: ProviderAdapter, @unchecked Sendable {
    let id: String
    let type: ProviderDescriptor.ProviderType
    var isAvailable: Bool = true
    var shouldFail: Bool = false
    
    init(id: String, type: ProviderDescriptor.ProviderType) {
        self.id = id
        self.type = type
    }
    
    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: type,
            transport: type == .local ? .inProcess : .http,
            supports: ProviderDescriptor.SupportsCapabilities(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_text"]
        )
    }
    
    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: isAvailable)
    }
    
    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        if shouldFail {
            throw createAuthError(message: "Invalid API Key", runId: context.runId, providerId: id)
        }
        return TaskResult(
            runId: context.runId,
            output: Output(text: "Hello from \(id)"),
            finishReason: FinishReason.stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }
}

struct MockRoutePlanner: RoutePlanning {
    let plan: SharedPlannerRoutePlan?

    func planRoute(input: SharedPlannerInput) -> SharedPlannerRoutePlan? {
        plan
    }
}

/// Captures the planner input so tests can assert what the Swift host actually
/// hands the shared route core.
final class CapturingRoutePlanner: RoutePlanning, @unchecked Sendable {
    let plan: SharedPlannerRoutePlan?
    private(set) var capturedInput: SharedPlannerInput?

    init(plan: SharedPlannerRoutePlan?) {
        self.plan = plan
    }

    func planRoute(input: SharedPlannerInput) -> SharedPlannerRoutePlan? {
        capturedInput = input
        return plan
    }
}

/// Test double for the Apple provider runtime seam.
///
/// Keeps provider tests independent of the host OS, hardware eligibility, and
/// Apple Intelligence model readiness.
final class MockAppleFoundationModelsRuntime: AppleFoundationModelsRuntime, @unchecked Sendable {
    var availabilityValue: AppleFoundationModelsAvailability = .available
    var responseText = "Apple response"
    var thrownError: Error?
    private(set) var receivedPrompt: String?
    private(set) var receivedOptions: AppleFoundationModelsGenerationOptions?

    func availability() async -> AppleFoundationModelsAvailability {
        availabilityValue
    }

    func respond(to prompt: String, options: AppleFoundationModelsGenerationOptions) async throws -> String {
        receivedPrompt = prompt
        receivedOptions = options
        if let thrownError {
            throw thrownError
        }
        return responseText
    }
}

// MARK: - Tests

final class IndeRunTests: XCTestCase {
    private var registry: ProviderRegistry!
    private var connectivity: MockConnectivityService!
    private var clock: MockClockService!
    private var telemetry: MockTelemetryService!
    private var hostServices: HostServices!
    private var inderun: IndeRun!
    
    override func setUp() {
        super.setUp()
        registry = ProviderRegistry()
        connectivity = MockConnectivityService()
        clock = MockClockService()
        telemetry = MockTelemetryService()
        hostServices = HostServices(
            connectivity: connectivity,
            clock: clock,
            telemetry: telemetry
        )
        inderun = IndeRun(registry: registry, hostServices: hostServices)
    }
    
    func testRegistry() throws {
        let p1 = MockProvider(id: "local_p", type: .local)
        try registry.register(p1)
        XCTAssertEqual(registry.list().count, 1)
        XCTAssertEqual(registry.get(id: "local_p")?.describe().id, "local_p")
        
        // Throws on duplicate registration
        XCTAssertThrowsError(try registry.register(p1))
    }

    func testCheckCapabilitiesReturnsSnapshotsWithoutExecutingRun() async throws {
        let available = MockProvider(id: "local_p", type: .local)
        let unavailable = MockProvider(id: "cloud_p", type: .cloud)
        unavailable.isAvailable = false
        unavailable.shouldFail = true
        try registry.register(available)
        try registry.register(unavailable)

        let snapshots = await inderun.checkCapabilities()

        XCTAssertEqual(snapshots.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.providerId, $0) })
        XCTAssertEqual(byId["local_p"]?.descriptor.id, "local_p")
        XCTAssertEqual(byId["local_p"]?.capabilities.available, true)
        XCTAssertEqual(byId["cloud_p"]?.descriptor.id, "cloud_p")
        XCTAssertEqual(byId["cloud_p"]?.capabilities.available, false)
    }

    func testRoutingOnDeviceSuccess() async throws {
        let p1 = MockProvider(id: "local_p", type: .local)
        try registry.register(p1)
        
        let request = TaskRequest(
            prompt: "Test on-device",
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )
        
        let result = try await inderun.run(request: request)
        XCTAssertEqual(result.output.text, "Hello from local_p")
        XCTAssertEqual(result.telemetry.providerUsed, "local_p")
        
        XCTAssertEqual(telemetry.events.count, 2)
        XCTAssertEqual(telemetry.events[0].type, .routeDecided)
        XCTAssertEqual(telemetry.events[1].type, .attemptSucceeded)
    }

    func testRouterUsesSharedPlannerSelectionWhenAvailable() async throws {
        let providerA = MockProvider(id: "local_a", type: .local)
        let providerB = MockProvider(id: "local_b", type: .local)
        try registry.register(providerA)
        try registry.register(providerB)

        let router = Router(
            registry: registry,
            planner: MockRoutePlanner(
                plan: SharedPlannerRoutePlan(
                    candidates: [],
                    explanation: SharedPlannerExplanation(
                        selectedProviderId: "local_b",
                        summary: "Selected provider 'local_b' from shared Rust planner."
                    ),
                    failureCode: nil,
                    fallbackProviderIds: ["local_a"],
                    rejectedProviders: [],
                    selectedProviderId: "local_b",
                )
            )
        )

        let selection = try await router.selectRoute(
            request: TaskRequest(
                prompt: "shared planner",
                constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
            ),
            hostServices: hostServices
        )

        XCTAssertEqual(selection.provider.describe().id, "local_b")
        XCTAssertTrue(selection.explanation.contains("shared Rust planner"))
    }
    
    func testPlannerInputCarriesInteractionModeAndStreamingCapability() async throws {
        let provider = MockProvider(id: "local_a", type: .local)
        try registry.register(provider)

        let planner = CapturingRoutePlanner(
            plan: SharedPlannerRoutePlan(
                candidates: [Candidate(order: 0, providerId: "local_a")],
                explanation: SharedPlannerExplanation(
                    selectedProviderId: "local_a",
                    summary: "Selected provider 'local_a'."
                ),
                failureCode: nil,
                fallbackProviderIds: [],
                rejectedProviders: [],
                selectedProviderId: "local_a"
            )
        )

        _ = try await Router(registry: registry, planner: planner).selectRoute(
            request: TaskRequest(prompt: "planner input"),
            hostServices: hostServices
        )

        let input = try XCTUnwrap(planner.capturedInput)
        // The Swift SDK is Mode 1 only until ProviderAdapter gains stream().
        XCTAssertEqual(input.interactionMode, .run)
        let descriptor = try XCTUnwrap(input.providers.first?.descriptor)
        XCTAssertEqual(descriptor.supports.streaming, false)
        XCTAssertEqual(descriptor.cancel, .soft)
    }

    func testRoutePlanDecodesStreamingRejectionReasons() throws {
        let json = """
        {
          "candidates": [],
          "fallbackProviderIds": [],
          "failureCode": "capability_mismatch",
          "explanation": { "summary": "No provider capable of streaming was found." },
          "rejectedProviders": [
            {
              "providerId": "local_a",
              "reasons": [
                { "code": "streaming_not_supported", "message": "no streaming" },
                { "code": "streaming_unavailable", "message": "cannot stream here" }
              ]
            }
          ]
        }
        """

        let plan = try SharedPlannerRoutePlan(json)

        XCTAssertEqual(plan.failureCode, .capabilityMismatch)
        XCTAssertEqual(
            plan.rejectedProviders.first?.reasons.map(\.code),
            [.streamingNotSupported, .streamingUnavailable]
        )
    }

    func testRoutingOnDeviceMismatch() async throws {
        let request = TaskRequest(
            prompt: "Test missing device",
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )
        
        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have thrown CapabilityMismatch")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .CapabilityMismatch)
        }
        
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertEqual(telemetry.events[0].type, .attemptFailed)
    }
    
    /// Regression test: a cloud provider must never appear as a *fallback* candidate under
    /// `localRequired`, even when the primary (local) provider fails at execution time and even
    /// though the cloud provider is otherwise available. The Swift-side fallback route planner
    /// (`Router.createFallbackPlan`, used whenever the shared Rust route-core dylib isn't loaded --
    /// which is always true on iOS) previously applied its cloud/privacy constraint filter only
    /// when picking the primary candidate, not when building the fallback list, so a failing local
    /// provider could silently fall through to a cloud provider under `Local Only`.
    func testRoutingLocalRequiredNeverFallsBackToCloudProvider() async throws {
        let local = MockProvider(id: "local_p", type: .local)
        local.shouldFail = true
        let cloud = MockProvider(id: "cloud_p", type: .cloud)
        try registry.register(local)
        try registry.register(cloud)

        let request = TaskRequest(
            prompt: "Test local-required never falls back to cloud",
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )

        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have thrown rather than falling back to the cloud provider")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.providerId, "local_p")
            XCTAssertNotEqual(err.providerId, "cloud_p")
        }
    }

    func testRoutingCloudOffline() async throws {
        let p1 = MockProvider(id: "cloud_p", type: .cloud)
        try registry.register(p1)
        
        connectivity.online = false
        
        let request = TaskRequest(
            prompt: "Test offline cloud",
            constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)
        )
        
        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have thrown Offline")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .Offline)
        }
    }
    
    func testValidationFailure() async throws {
        // Invalid request shape: schema-backed types can only represent valid enum constants,
        // but runtime validation still rejects requests without text input.
        let request = TaskRequest(
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )
        
        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have failed validation")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .Internal)
            XCTAssertTrue(err.message.contains("Validation failed"))
        }

        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertNoThrow(try JSONEncoder().encode(telemetry.events[0]))
    }

    func testValidationRejectsSchemaMinLengthViolations() async throws {
        let request = TaskRequest(
            requestId: "",
            prompt: "",
            messages: [Message(role: .user, content: "")],
            constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil),
            authContextRef: ""
        )

        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have failed validation")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .Internal)
            XCTAssertTrue(err.message.contains("requestId must be non-empty"))
            XCTAssertTrue(err.message.contains("prompt must be non-empty"))
            XCTAssertTrue(err.message.contains("authContextRef must be non-empty"))
            XCTAssertTrue(err.message.contains("messages[].content must be non-empty"))
        }
    }
    
    func testProviderExecutionFailure() async throws {
        let p1 = MockProvider(id: "cloud_p", type: .cloud)
        p1.shouldFail = true
        try registry.register(p1)
        
        connectivity.online = true
        
        let request = TaskRequest(
            prompt: "Fail me",
            constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)
        )
        
        do {
            _ = try await inderun.run(request: request)
            XCTFail("Should have failed on provider level")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .AuthError)
            XCTAssertEqual(err.providerId, "cloud_p")
        }
        
        XCTAssertEqual(telemetry.events.count, 2)
        XCTAssertEqual(telemetry.events[0].type, .routeDecided)
        XCTAssertEqual(telemetry.events[1].type, .attemptFailed)
        XCTAssertNoThrow(try JSONEncoder().encode(telemetry.events[1]))
    }

    func testSchemaBackedContractsDecodeFromCanonicalJSON() throws {
        let decoder = JSONDecoder()

        let requestJSON = """
        {
          "schemaVersion": "1.0",
          "task": { "kind": "text_to_text" },
          "prompt": "Hello",
          "constraints": { "privacy": "cloud_required" },
          "authContextRef": "openai/main"
        }
        """
        let request = try decoder.decode(TaskRequest.self, from: Data(requestJSON.utf8))
        XCTAssertEqual(request.schemaVersion, .the10)
        XCTAssertEqual(request.task.kind, .textToText)
        XCTAssertEqual(request.constraints?.privacy, .cloudRequired)
        XCTAssertEqual(request.authContextRef, "openai/main")

        let resultJSON = """
        {
          "schemaVersion": "1.0",
          "runId": "run_123",
          "output": { "type": "text", "text": "Hi" },
          "finishReason": "stop",
          "telemetry": { "providerUsed": "cloud_p", "totalMs": 12.5 }
        }
        """
        let result = try decoder.decode(TaskResult.self, from: Data(resultJSON.utf8))
        XCTAssertEqual(result.output.text, "Hi")
        XCTAssertEqual(result.finishReason, FinishReason.stop)
        XCTAssertEqual(result.telemetry.providerUsed, "cloud_p")

        let httpRequestJSON = """
        {
          "method": "POST",
          "url": "https://example.invalid/v1",
          "headers": { "Content-Type": "application/json" },
          "body": "{}",
          "timeoutMs": 1000
        }
        """
        let httpRequest = try decoder.decode(HttpRequest.self, from: Data(httpRequestJSON.utf8))
        XCTAssertEqual(httpRequest.method, .post)
        XCTAssertEqual(httpRequest.timeoutMs, 1000)

        let telemetryJSON = """
        {
          "type": "route_decided",
          "runId": "run_123",
          "timestamp": 1000,
          "payload": { "providerId": "cloud_p", "durationMs": 10.5 }
        }
        """
        let event = try decoder.decode(TelemetryEvent.self, from: Data(telemetryJSON.utf8))
        XCTAssertEqual(event.type, .routeDecided)
        XCTAssertEqual(event.payload["providerId"]?.value as? String, "cloud_p")
    }

    func testSystemClockReturnsMilliseconds() {
        let clock = SystemClockService()
        XCTAssertGreaterThan(clock.now(), 0)
        XCTAssertGreaterThan(clock.monotonicNow() ?? 0, 0)
    }

    func testKeychainSecureStorageRoundTripBySlotId() async {
        let storage = KeychainSecureStorageService(service: "dev.inderun.tests")
        let slotId = "test-\(UUID().uuidString)"

        await storage.deleteSecret(slotId: slotId)
        await storage.setSecret(slotId: slotId, secret: "secret-value")

        let stored = await storage.getSecret(slotId: slotId)
        XCTAssertEqual(stored, "secret-value")

        await storage.deleteSecret(slotId: slotId)
        let deleted = await storage.getSecret(slotId: slotId)
        XCTAssertNil(deleted)
    }

    func testAppleFoundationModelsDescriptor() {
        let provider = AppleFoundationModelsProvider(runtime: MockAppleFoundationModelsRuntime())
        let descriptor = provider.describe()

        XCTAssertEqual(descriptor.id, AppleFoundationModelsProvider.defaultId)
        XCTAssertEqual(descriptor.type, .local)
        XCTAssertEqual(descriptor.transport, .systemService)
        XCTAssertTrue(descriptor.supports.run)
        XCTAssertFalse(descriptor.supports.streaming)
        XCTAssertFalse(descriptor.supports.realtime)
        XCTAssertEqual(descriptor.cancel, .soft)
        XCTAssertEqual(descriptor.tasks, ["text_to_text"])
        XCTAssertEqual(descriptor.privacy?.dataLeavesDevice, false)
    }

    func testAppleFoundationModelsCapabilitiesUnavailable() async {
        let runtime = MockAppleFoundationModelsRuntime()
        runtime.availabilityValue = .unavailable(reason: "model not ready")
        let provider = AppleFoundationModelsProvider(runtime: runtime)

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
    }

    func testAppleFoundationModelsRunReturnsTaskResult() async throws {
        let runtime = MockAppleFoundationModelsRuntime()
        runtime.responseText = "Bonjour"
        let provider = AppleFoundationModelsProvider(runtime: runtime)
        let request = TaskRequest(
            prompt: "Translate hello",
            generation: Generation(maxOutputTokens: 32, seed: 123, stop: ["."], temperature: 0.2, topP: 0.9),
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )

        let result = try await provider.run(
            request: request,
            context: RunContext(runId: "run_apple", hostServices: hostServices)
        )

        XCTAssertEqual(result.runId, "run_apple")
        XCTAssertEqual(result.output.text, "Bonjour")
        XCTAssertEqual(result.finishReason, FinishReason.stop)
        XCTAssertEqual(result.telemetry.providerUsed, AppleFoundationModelsProvider.defaultId)
        XCTAssertEqual(runtime.receivedPrompt, "Translate hello")
        XCTAssertEqual(runtime.receivedOptions?.maxOutputTokens, 32)
        XCTAssertEqual(runtime.receivedOptions?.temperature, 0.2)
    }

    func testAppleFoundationModelsRunNormalizesMessages() async throws {
        let runtime = MockAppleFoundationModelsRuntime()
        let provider = AppleFoundationModelsProvider(runtime: runtime)
        let request = TaskRequest(
            prompt: "ignored when messages exist",
            messages: [
                Message(role: .system, content: "Be concise."),
                Message(role: .user, content: "Summarize this.")
            ],
            constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
        )

        _ = try await provider.run(
            request: request,
            context: RunContext(runId: "run_messages", hostServices: hostServices)
        )

        XCTAssertEqual(runtime.receivedPrompt, "system: Be concise.\nuser: Summarize this.")
    }

    func testAppleFoundationModelsRunThrowsCapabilityMismatchWhenUnavailable() async {
        let runtime = MockAppleFoundationModelsRuntime()
        runtime.availabilityValue = .unavailable(reason: "Apple Intelligence disabled")
        let provider = AppleFoundationModelsProvider(runtime: runtime)
        let request = TaskRequest(prompt: "Hello", constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil))

        do {
            _ = try await provider.run(
                request: request,
                context: RunContext(runId: "run_unavailable", hostServices: hostServices)
            )
            XCTFail("Should have thrown CapabilityMismatch")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .CapabilityMismatch)
            XCTAssertEqual(err.providerId, AppleFoundationModelsProvider.defaultId)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testAppleFoundationModelsRunMapsUnexpectedFailureToInternal() async {
        struct RuntimeFailure: Error {}

        let runtime = MockAppleFoundationModelsRuntime()
        runtime.thrownError = RuntimeFailure()
        let provider = AppleFoundationModelsProvider(runtime: runtime)
        let request = TaskRequest(prompt: "Hello", constraints: TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil))

        do {
            _ = try await provider.run(
                request: request,
                context: RunContext(runId: "run_failure", hostServices: hostServices)
            )
            XCTFail("Should have thrown Internal")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .Internal)
            XCTAssertEqual(err.providerId, AppleFoundationModelsProvider.defaultId)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testAppleProviderRegistryFactoryRegistersFoundationModelsProvider() throws {
        let registry = try AppleProviderRegistryFactory.makeDefaultRegistry()

        XCTAssertNotNil(registry.get(id: AppleFoundationModelsProvider.defaultId))
        XCTAssertEqual(registry.list().count, 1)
    }

    func testOpenAIProviderPostsResponsesRequest() async throws {
        let httpClient = MockHttpClientService(
            responses: [
                .success(
                    HttpResponse(
                        body: #"{"output_text":"Hello from Responses.","status":"completed","usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}"#,
                        headers: [:],
                        status: 200,
                        statusText: "OK"
                    )
                )
            ]
        )
        let secureStorage = MockSecureStorageService(slots: ["openai-dev": "sk-from-slot"])
        let provider = OpenAIProvider(
            options: OpenAIProviderOptions(model: "gpt-5.2", authContextRef: "openai-dev", timeoutMs: 30_000)
        )
        let request = TaskRequest(
            prompt: "Say hello.",
            generation: Generation(maxOutputTokens: 64, seed: nil, stop: ["END"], temperature: 0.2, topP: 0.9),
            constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)
        )
        let hostServices = HostServices(
            connectivity: connectivity,
            secureStorage: secureStorage,
            clock: clock,
            httpClient: httpClient
        )

        let result = try await provider.run(
            request: request,
            context: RunContext(runId: "run_openai", hostServices: hostServices)
        )

        XCTAssertEqual(result.output.text, "Hello from Responses.")
        XCTAssertEqual(result.finishReason, FinishReason.stop)
        XCTAssertEqual(result.usage?.inputTokens, 3)
        XCTAssertEqual(result.usage?.outputTokens, 4)
        XCTAssertEqual(result.usage?.totalTokens, 7)
        let requests = await httpClient.snapshotRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers?["Authorization"], "Bearer sk-from-slot")
        XCTAssertEqual(requests[0].timeoutMs, 30_000)

        let bodyData = try XCTUnwrap(requests[0].body?.data(using: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.2")
        XCTAssertEqual(body["input"] as? String, "Say hello.")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 64)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["top_p"] as? Double, 0.9)
        XCTAssertEqual(body["stop"] as? [String], ["END"])
    }

    func testOpenAIProviderMapsMessagesToDeveloperRole() async throws {
        let httpClient = MockHttpClientService(
            responses: [
                .success(HttpResponse(body: #"{"output_text":"Done."}"#, headers: [:], status: 200, statusText: "OK"))
            ]
        )
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)
        let request = TaskRequest(
            messages: [
                Message(role: .system, content: "Be concise."),
                Message(role: .user, content: "Say hello.")
            ],
            constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)
        )

        _ = try await provider.run(
            request: request,
            context: RunContext(runId: "run_messages", hostServices: hostServices)
        )

        let requests = await httpClient.snapshotRequests()
        let bodyData = try XCTUnwrap(requests[0].body?.data(using: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(input, [
            ["role": "developer", "content": "Be concise."],
            ["role": "user", "content": "Say hello."]
        ])
    }

    func testOpenAIProviderRequiresAuthContextRefWhenAuthEnabled() async {
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2"))
        let hostServices = HostServices(
            connectivity: connectivity,
            secureStorage: MockSecureStorageService(),
            clock: clock,
            httpClient: MockHttpClientService(responses: [])
        )
        let request = TaskRequest(prompt: "Hello", constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil))

        do {
            _ = try await provider.run(
                request: request,
                context: RunContext(runId: "run_auth", hostServices: hostServices)
            )
            XCTFail("Should have thrown AuthError")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .AuthError)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testOpenAIProviderMapsRateLimitErrors() async {
        let httpClient = MockHttpClientService(
            responses: [
                .success(
                    HttpResponse(
                        body: #"{"error":{"message":"Too many requests","type":"rate_limit"}}"#,
                        headers: ["Retry-After": "2"],
                        status: 429,
                        statusText: "Too Many Requests"
                    )
                )
            ]
        )
        let hostServices = HostServices(
            connectivity: connectivity,
            clock: clock,
            httpClient: httpClient
        )
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))

        do {
            _ = try await provider.run(
                request: TaskRequest(prompt: "Hello", constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)),
                context: RunContext(runId: "run_rate", hostServices: hostServices)
            )
            XCTFail("Should have thrown RateLimited")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .RateLimited)
            XCTAssertEqual(error.retryAfterMs, 2_000)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testOpenAIProviderPropagatesCancellation() async {
        let httpClient = MockHttpClientService(responses: [.failure(TestCancellationError())])
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)

        do {
            _ = try await provider.run(
                request: TaskRequest(prompt: "Hello", constraints: TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)),
                context: RunContext(runId: "run_cancel", hostServices: hostServices)
            )
            XCTFail("Should have thrown Unavailable")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testOpenAIProviderCapabilitiesReportsUnavailableOn5xxReachabilityProbe() async {
        let httpClient = MockHttpClientService(
            responses: [
                .success(HttpResponse(body: "", headers: [:], status: 502, statusText: "Bad Gateway"))
            ]
        )
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
        XCTAssertEqual(capabilities.reason, "OpenAI Responses endpoint returned HTTP 502.")
        let requests = await httpClient.snapshotRequests()
        XCTAssertEqual(requests.first?.method, .get)
    }

    func testOpenAIProviderCapabilitiesTreatsNon5xxReachabilityResponseAsAvailable() async {
        let httpClient = MockHttpClientService(
            responses: [
                .success(HttpResponse(body: "", headers: [:], status: 405, statusText: "Method Not Allowed"))
            ]
        )
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertTrue(capabilities.available)
    }

    func testOpenAIProviderCapabilitiesReportsUnavailableWhenReachabilityProbeThrows() async {
        let httpClient = MockHttpClientService(responses: [.failure(TestCancellationError())])
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
        XCTAssertEqual(capabilities.reason, "OpenAI Responses endpoint is unreachable.")
    }

    func testOpenAIProviderCapabilitiesCachesReachabilityResultWithinCacheWindow() async {
        let httpClient = MockHttpClientService(
            responses: [
                .success(HttpResponse(body: "", headers: [:], status: 200, statusText: "OK"))
            ]
        )
        let provider = OpenAIProvider(options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none))
        let hostServices = HostServices(connectivity: connectivity, clock: clock, httpClient: httpClient)

        let first = await provider.capabilities(host: hostServices)
        let second = await provider.capabilities(host: hostServices)

        XCTAssertTrue(first.available)
        XCTAssertTrue(second.available)
        let requests = await httpClient.snapshotRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testAppleCloudProviderRegistryFactoryRegistersOpenAIProvider() throws {
        let registry = try AppleCloudProviderRegistryFactory.makeOpenAIRegistry(
            options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none)
        )

        XCTAssertNotNil(registry.get(id: "openai"))
        XCTAssertEqual(registry.list().count, 1)
    }

    // MARK: - ONNX Runtime Apple provider

    private func makeOnnxModelPackage(sourceType: SourceType = .bundled) -> ModelPackage {
        ModelPackage(
            files: Files(config: nil, external: nil, filesRequired: ["model.onnx"], tokenizer: "tokenizer.json"),
            format: .onnx,
            id: "test-model",
            integrity: nil,
            license: nil,
            limits: nil,
            runtime: nil,
            source: Source(ref: "models/test-model", sourceType: sourceType),
            tasks: ["text_to_text"],
            version: "1.0"
        )
    }

    func testOnnxAppleDescriptor() {
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: createFixtureOnnxRuntime())
        )
        let descriptor = provider.describe()

        XCTAssertEqual(descriptor.id, OnnxRuntimeAppleProvider.defaultId)
        XCTAssertEqual(descriptor.type, .local)
        XCTAssertEqual(descriptor.transport, .inProcess)
        XCTAssertTrue(descriptor.supports.run)
        XCTAssertFalse(descriptor.supports.streaming)
        XCTAssertEqual(descriptor.cancel, .soft)
        XCTAssertEqual(descriptor.tasks, ["text_to_text"])
        XCTAssertEqual(descriptor.privacy?.dataLeavesDevice, false)
    }

    func testOnnxAppleCapabilitiesRejectsMalformedModelPackage() async {
        let modelPackage = ModelPackage(
            files: nil, format: .onnx, id: "", integrity: nil, license: nil, limits: nil,
            runtime: nil, source: nil, tasks: nil, version: nil
        )
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: modelPackage, runtime: createFixtureOnnxRuntime())
        )

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
        XCTAssertTrue(capabilities.reason?.contains("model package malformed") ?? false)
    }

    func testOnnxAppleCapabilitiesRejectsDeferredSourceTypes() async {
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(
                modelPackage: makeOnnxModelPackage(sourceType: .registry),
                runtime: createFixtureOnnxRuntime()
            )
        )

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
        XCTAssertTrue(capabilities.reason?.contains("registry") ?? false)
    }

    func testOnnxAppleCapabilitiesAcceptsFilesystemSource() async {
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(
                modelPackage: makeOnnxModelPackage(sourceType: .filesystem),
                runtime: createFixtureOnnxRuntime()
            )
        )

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertTrue(capabilities.available)
    }

    func testOnnxAppleCapabilitiesRejectsUnsupportedTask() async {
        var modelPackage = makeOnnxModelPackage()
        modelPackage.tasks = ["image_to_text"]
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: modelPackage, runtime: createFixtureOnnxRuntime())
        )

        let capabilities = await provider.capabilities(host: hostServices)

        XCTAssertFalse(capabilities.available)
        XCTAssertTrue(capabilities.reason?.contains("unsupported task") ?? false)
    }

    func testOnnxAppleRunReturnsTaskResultFromFixture() async throws {
        let runtime = createFixtureOnnxRuntime(
            options: FixtureOnnxRuntimeOptions(respond: { input in
                OnnxGenerationOutput(text: "Bonjour, \(input.messages.last?.content ?? "")")
            })
        )
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: runtime)
        )
        let request = TaskRequest(prompt: "world")

        let result = try await provider.run(
            request: request,
            context: RunContext(runId: "run_onnx_apple", hostServices: hostServices)
        )

        XCTAssertEqual(result.runId, "run_onnx_apple")
        XCTAssertEqual(result.output.text, "Bonjour, world")
        XCTAssertEqual(result.finishReason, .stop)
        XCTAssertEqual(result.telemetry.providerUsed, OnnxRuntimeAppleProvider.defaultId)
    }

    func testOnnxAppleRunThrowsCapabilityMismatchWhenUnavailable() async {
        let runtime = createFixtureOnnxRuntime(
            options: FixtureOnnxRuntimeOptions(availability: OnnxRuntimeAvailability(available: false, reason: "model files missing"))
        )
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: runtime)
        )
        let request = TaskRequest(prompt: "Hello")

        do {
            _ = try await provider.run(request: request, context: RunContext(runId: "run_unavailable", hostServices: hostServices))
            XCTFail("Should have thrown CapabilityMismatch")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .CapabilityMismatch)
            XCTAssertEqual(err.providerId, OnnxRuntimeAppleProvider.defaultId)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testOnnxAppleRunMapsRuntimeErrorKindsToErrorClasses() async {
        let cases: [(OnnxRuntimeErrorKind, IndeRunErrorClass)] = [
            (.capability, .CapabilityMismatch),
            (.unavailable, .Unavailable),
            (.timeout, .Timeout),
            (.internalFailure, .Internal)
        ]

        for (kind, expectedClass) in cases {
            let runtime = createFixtureOnnxRuntime(
                options: FixtureOnnxRuntimeOptions(failWith: OnnxRuntimeError(kind: kind, message: "runtime failure"))
            )
            let provider = OnnxRuntimeAppleProvider(
                options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: runtime)
            )
            let request = TaskRequest(prompt: "Hello")

            do {
                _ = try await provider.run(request: request, context: RunContext(runId: "run_error", hostServices: hostServices))
                XCTFail("Should have thrown for kind \(kind)")
            } catch let err as IndeRunException {
                XCTAssertEqual(err.errorClass, expectedClass)
            } catch {
                XCTFail("Expected IndeRunException for kind \(kind)")
            }
        }
    }

    func testOnnxAppleModelPackageValidationRejectsUrlUserinfoInSourceRef() {
        var modelPackage = makeOnnxModelPackage()
        modelPackage.source = Source(ref: "https://user:pass@example.com/model", sourceType: .bundled)

        let issues = getModelPackageValidationIssues(modelPackage)

        XCTAssertTrue(issues.contains { $0.path == "/source/ref" })
    }

    func testOnnxAppleModelPackageValidationAllowsPlainUrlInSourceRef() {
        var modelPackage = makeOnnxModelPackage()
        modelPackage.source = Source(ref: "https://example.com/model", sourceType: .bundled)

        let issues = getModelPackageValidationIssues(modelPackage)

        XCTAssertTrue(issues.isEmpty)
    }

    func testOnnxAppleRunThrowsRawCancellationErrorWithoutNormalizing() async {
        let runtime = createFixtureOnnxRuntime(options: FixtureOnnxRuntimeOptions(delay: .seconds(10)))
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: runtime)
        )
        let request = TaskRequest(prompt: "Hello")

        let runTask = Task {
            try await provider.run(request: request, context: RunContext(runId: "run_cancel", hostServices: hostServices))
        }
        runTask.cancel()

        do {
            _ = try await runTask.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // expected: real Task cancellation propagates raw, matching OpenAIProvider/IndeRun.swift
        } catch {
            XCTFail("Expected raw CancellationError, got \(error)")
        }
    }

    func testOnnxAppleRunThrowsTimeoutWhenGenerationExceedsDeadline() async {
        let runtime = createFixtureOnnxRuntime(options: FixtureOnnxRuntimeOptions(delay: .seconds(10)))
        let provider = OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(modelPackage: makeOnnxModelPackage(), runtime: runtime, timeout: .milliseconds(50))
        )
        let request = TaskRequest(prompt: "Hello")

        do {
            _ = try await provider.run(request: request, context: RunContext(runId: "run_timeout", hostServices: hostServices))
            XCTFail("Should have thrown Timeout")
        } catch let err as IndeRunException {
            XCTAssertEqual(err.errorClass, .Timeout)
        } catch {
            XCTFail("Expected IndeRunException, got \(error)")
        }
    }
}

// MARK: - Streaming HTTP Host Service

/// Feeds a scripted response through `URLSession` so the streaming client can be
/// exercised without a network. Each script entry is delivered as its own
/// `URLProtocol` data callback, which is what makes "bytes arrive before the
/// response completes" observable.
final class ScriptedStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: @unchecked Sendable {
        var status: Int
        var headers: [String: String]
        var chunks: [String]
        var chunkDelay: TimeInterval
        /// Never sends the response head, so the caller's head deadline decides.
        var withholdResponse: Bool = false
        /// Holds the rest of the response back until `releaseGate()` is called,
        /// so a test can prove it observed earlier bytes *before* the transfer
        /// could possibly have completed. This replaces latency measurements:
        /// a buffering client cannot get past the gate at any machine speed.
        var gateAfterChunkIndex: Int?
    }

    private static let lock = NSLock()
    private static var scriptStorage = Script(status: 200, headers: [:], chunks: [], chunkDelay: 0)
    private static var stoppedStorage = false
    private static var gateStorage = DispatchSemaphore(value: 0)
    /// Liveness backstop only: a wedged test finishes instead of hanging the
    /// whole job. No assertion depends on this budget.
    private static var gateDeadline: DispatchTime { .now() + 10 }

    static var script: Script {
        get { lock.lock(); defer { lock.unlock() }; return scriptStorage }
        set {
            lock.lock()
            scriptStorage = newValue
            stoppedStorage = false
            // A fresh gate per script keeps signals from leaking between tests.
            gateStorage = DispatchSemaphore(value: 0)
            lock.unlock()
        }
    }

    private static var gate: DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }; return gateStorage
    }

    /// Lets the scripted response continue past its gated chunk.
    static func releaseGate() {
        gate.signal()
    }

    static var stopped: Bool {
        lock.lock(); defer { lock.unlock() }; return stoppedStorage
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.script
        if script.withholdResponse { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: script.status,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for (index, chunk) in script.chunks.enumerated() {
                if Self.stopped { return }
                if script.chunkDelay > 0 {
                    Thread.sleep(forTimeInterval: script.chunkDelay)
                }
                if Self.stopped { return }
                self.client?.urlProtocol(self, didLoad: Data(chunk.utf8))
                if index == script.gateAfterChunkIndex {
                    _ = Self.gate.wait(timeout: Self.gateDeadline)
                    // The transfer may have been torn down while we waited.
                    if Self.stopped { return }
                }
            }
            if Self.stopped { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stoppedStorage = true
        Self.lock.unlock()
    }
}

/// Bounds an await so a stream that never produces a value fails the test with a
/// readable error instead of hanging the run. The budget is a liveness backstop,
/// not a latency assertion — tests must never depend on how long `body` takes.
/// It stays below `ScriptedStreamingURLProtocol`'s gate budget so a wedged test
/// reports the timeout rather than a confusing downstream assertion.
private func withTestTimeout<T: Sendable>(
    seconds: Double = 5,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw TestTimeoutError(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}

private struct TestTimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String {
        "Timed out after \(seconds)s waiting for a value that should have arrived immediately."
    }
}

final class URLSessionStreamingHttpClientServiceTests: XCTestCase {
    private func makeRequest(timeoutMs: Int? = 5000) -> HttpRequest {
        HttpRequest(
            body: nil,
            headers: nil,
            method: .get,
            timeoutMs: timeoutMs,
            url: "https://example.test/stream"
        )
    }

    private func collect(_ body: AsyncThrowingStream<Data, Error>) async throws -> [String] {
        var out: [String] = []
        for try await chunk in body {
            out.append(String(decoding: chunk, as: UTF8.self))
        }
        return out
    }

    func testResolvesHeadWithLowerCasedHeadersBeforeBody() async throws {
        ScriptedStreamingURLProtocol.script = .init(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: ["data: a\n\n"],
            chunkDelay: 0
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        let response = try await client.stream(request: makeRequest())

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        let body = try await collect(response.body).joined()
        XCTAssertEqual(body, "data: a\n\n")
    }

    func testSurfacesBytesBeforeTheResponseCompletes() async throws {
        // The fixture holds everything after the first chunk until this test
        // says so, so the first chunk is necessarily observed while the response
        // is still open. A buffering client would deadlock here rather than pass
        // slowly, which is why this needs no wall-clock budget.
        ScriptedStreamingURLProtocol.script = .init(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: ["data: one\n\n", "data: two\n\n", "data: three\n\n"],
            chunkDelay: 0,
            gateAfterChunkIndex: 0
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        let response = try await client.stream(request: makeRequest())

        var iterator = response.body.makeAsyncIterator()
        let first = try await withTestTimeout { try await iterator.next() }
        // Chunk boundaries are arbitrary by contract — this client flushes at
        // newlines — so the assertion is on content arriving early, not shape.
        XCTAssertEqual(String(decoding: first ?? Data(), as: UTF8.self), "data: one\n")

        ScriptedStreamingURLProtocol.releaseGate()
        var rest = ""
        while let chunk = try await iterator.next() {
            rest += String(decoding: chunk, as: UTF8.self)
        }
        XCTAssertEqual(rest, "\ndata: two\n\ndata: three\n\n")
    }

    func testExposesNonSuccessHeadAndErrorBody() async throws {
        ScriptedStreamingURLProtocol.script = .init(
            status: 429,
            headers: ["Retry-After": "3", "Content-Type": "application/json"],
            chunks: ["{\"error\":{\"message\":\"slow down\"}}"],
            chunkDelay: 0
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        let response = try await client.stream(request: makeRequest())

        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.headers["retry-after"], "3")
        let body = try await collect(response.body).joined()
        XCTAssertEqual(body, "{\"error\":{\"message\":\"slow down\"}}")
    }

    func testTimesOutWaitingForTheResponseHead() async throws {
        ScriptedStreamingURLProtocol.script = .init(
            status: 200,
            headers: [:],
            chunks: [],
            chunkDelay: 0,
            withholdResponse: true
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        do {
            _ = try await client.stream(request: makeRequest(timeoutMs: 50))
            XCTFail("Expected a head timeout")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Timeout)
        }
    }

    func testDoesNotImposeAnIdleDeadlineOnAnEstablishedStream() async throws {
        // The head deadline must not survive into the body: a gap longer than
        // timeoutMs on an established stream is normal, not a failure.
        ScriptedStreamingURLProtocol.script = .init(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: ["first\n", "second\n"],
            chunkDelay: 0.3
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        let response = try await client.stream(request: makeRequest(timeoutMs: 100))

        let body = try await collect(response.body).joined()
        XCTAssertEqual(body, "first\nsecond\n")
    }

    func testCancellingTheConsumingTaskTearsDownTheConnection() async throws {
        // Gated after the first chunk, so the stream is provably mid-flight when
        // the consumer is cancelled — no "sleep and hope" window.
        ScriptedStreamingURLProtocol.script = .init(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: Array(repeating: "data: x\n\n", count: 4),
            chunkDelay: 0,
            gateAfterChunkIndex: 0
        )

        let client = URLSessionStreamingHttpClientService(session: ScriptedStreamingURLProtocol.makeSession())
        let response = try await client.stream(request: makeRequest())

        let (firstChunkSeen, signalFirstChunk) = AsyncStream<Void>.makeStream()
        let task = Task { () -> Int in
            var count = 0
            for try await _ in response.body {
                count += 1
                if count == 1 { signalFirstChunk.yield(()) }
            }
            return count
        }

        var iterator = firstChunkSeen.makeAsyncIterator()
        _ = try await withTestTimeout { await iterator.next() }
        task.cancel()
        _ = try? await task.value

        // stopLoading() is how URLSession reports that the transfer was torn
        // down rather than left running in the background. Teardown is
        // asynchronous, so this polls until it lands rather than asserting how
        // fast it lands.
        var stopped = false
        for _ in 0 ..< 250 where !stopped {
            if ScriptedStreamingURLProtocol.stopped {
                stopped = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the fixture's worker unwind regardless of the outcome.
        ScriptedStreamingURLProtocol.releaseGate()
        XCTAssertTrue(stopped)
    }
}

// MARK: - SSE Framing

/// Drives `SseParser` from the shared cross-SDK vectors so the three
/// implementations of the protocol cannot drift apart.
final class SseParserConformanceTests: XCTestCase {
    private struct FramingCase: Decodable {
        let name: String
        let description: String
        let chunksHex: [String]
        let expected: [ExpectedEvent]
    }

    private struct ExpectedEvent: Decodable {
        let event: String?
        let data: String
        let id: String?
    }

    private struct Fixture: Decodable {
        let cases: [FramingCase]
    }

    private static func repositoryRoot() -> URL {
        // .../ios/IndeRun/Tests/IndeRunTests/IndeRunTests.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadFixture() throws -> Fixture {
        let url = Self.repositoryRoot()
            .appendingPathComponent("contracts/fixtures/streaming/sse-framing.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func bytes(fromHex hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    func testMatchesSharedFramingVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty)

        for framingCase in fixture.cases {
            var parser = SseParser()
            var received: [SseEvent] = []
            for hex in framingCase.chunksHex {
                received.append(contentsOf: parser.consume(bytes(fromHex: hex)))
            }
            received.append(contentsOf: parser.finish())

            let expected = framingCase.expected.map {
                SseEvent(event: $0.event, data: $0.data, id: $0.id)
            }
            XCTAssertEqual(received, expected, "\(framingCase.name): \(framingCase.description)")
        }
    }

    func testIsUnaffectedByChunking() {
        let raw = Array("event: a\ndata: one\n\ndata: two\n\n".utf8)
        var parser = SseParser()
        var received: [SseEvent] = []
        for byte in raw {
            received.append(contentsOf: parser.consume(Data([byte])))
        }
        received.append(contentsOf: parser.finish())

        XCTAssertEqual(received, [SseEvent(event: "a", data: "one"), SseEvent(data: "two")])
    }
}

// MARK: - Mode 2 Streaming

/// Scripted streaming provider mirroring `createFakeStreamProvider` in the Web
/// SDK's engine.stream tests, so both platforms are held to the same scenarios.
final class MockStreamProvider: StreamingProviderAdapter, @unchecked Sendable {
    struct Step {
        let event: ProviderStreamEvent
        let delayMs: UInt64
        /// Blocks this step until the run has actually been cancelled, so tests
        /// that cancel mid-stream do not race a fixed delay.
        let waitsForCancellation: Bool

        init(_ event: ProviderStreamEvent, delayMs: UInt64 = 0, waitsForCancellation: Bool = false) {
            self.event = event
            self.delayMs = delayMs
            self.waitsForCancellation = waitsForCancellation
        }
    }

    let id: String
    let script: [Step]
    let throwAfterScript: Error?
    let declaresStreaming: Bool
    private let lock = NSLock()
    private var attempts = 0

    init(id: String, script: [Step], throwAfterScript: Error? = nil, declaresStreaming: Bool = true) {
        self.id = id
        self.script = script
        self.throwAfterScript = throwAfterScript
        self.declaresStreaming = declaresStreaming
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
            supports: ProviderDescriptor.SupportsCapabilities(
                run: true,
                streaming: declaresStreaming,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_text"]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        TaskResult(
            runId: context.runId,
            output: Output(text: "unused"),
            finishReason: FinishReason.stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        lock.lock()
        attempts += 1
        lock.unlock()

        return AsyncThrowingStream { continuation in
            Task { [script, throwAfterScript] in
                for step in script {
                    if step.waitsForCancellation {
                        // Bounded so a broken cancellation path fails the test
                        // instead of hanging it; the loop exits the moment
                        // cancellation is observed.
                        for _ in 0 ..< 500 where !context.cancellation.isCancelled {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                    } else if step.delayMs > 0 {
                        try? await Task.sleep(nanoseconds: step.delayMs * 1_000_000)
                    }
                    if context.cancellation.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(step.event)
                }
                if let throwAfterScript {
                    continuation.finish(throwing: throwAfterScript)
                    return
                }
                continuation.finish()
            }
        }
    }
}

/// Declares Mode 2 support in its descriptor but does not conform to
/// `StreamingProviderAdapter`, which is the mismatch the router must catch.
final class DeclaredOnlyStreamProvider: ProviderAdapter, @unchecked Sendable {
    let id: String

    init(id: String) {
        self.id = id
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
            supports: ProviderDescriptor.SupportsCapabilities(
                run: true,
                streaming: true,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_text"]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: true)
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        TaskResult(
            runId: context.runId,
            output: Output(text: "unused"),
            finishReason: FinishReason.stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }
}

final class StreamOrchestrationTests: XCTestCase {
    private func makeHost() -> HostServices {
        HostServices(
            connectivity: MockConnectivityService(),
            clock: MockClockService()
        )
    }

    private func makeRequest(requestId: String? = nil) -> TaskRequest {
        TaskRequest(
            requestId: requestId,
            task: TaskDescriptor(kind: .textToText),
            prompt: "Hello"
        )
    }

    private func drain(_ run: StreamRun) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in run.events {
            events.append(event)
        }
        return events
    }

    func testDeliversContentDeltasAndACompletedTerminal() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [
            .init(.delta(text: "Hello")),
            .init(.delta(text: " world")),
            .init(.done(finalText: "Hello world"))
        ]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let run = try await engine.stream(request: makeRequest())
        let events = try await drain(run)

        XCTAssertEqual(events.map { $0.type }, ["content_delta", "content_delta", "terminal"])
        XCTAssertEqual(events.map { $0.sequence }, [0, 1, 2])
        XCTAssertEqual(events.last?.payload?.outcome, .completed)
        XCTAssertEqual(events.last?.payload?.finalText, "Hello world")
    }

    func testCarriesFinishReasonAndUsageOnCompletion() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [
            .init(.delta(text: "trunc")),
            .init(.done(
                finalText: "trunc",
                finishReason: .length,
                usage: TaskResultUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3)
            ))
        ]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.last?.payload?.finishReason, .length)
        XCTAssertEqual(events.last?.payload?.usage?.totalTokens, 3)
    }

    func testRejectsWhenNoRegisteredProviderCanStream() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockProvider(id: "p_run_only", type: .local))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        do {
            _ = try await engine.stream(request: makeRequest(requestId: "req-42"))
            XCTFail("Expected the stream to be refused")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
            XCTAssertEqual(error.runId, "req-42")
        } catch {
            XCTFail("Expected IndeRunException, got \(error)")
        }
    }

    func testRejectsAProviderThatDeclaresStreamingWithoutImplementingIt() async throws {
        let registry = ProviderRegistry()
        try registry.register(DeclaredOnlyStreamProvider(id: "p_declared"))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        do {
            _ = try await engine.stream(request: makeRequest())
            XCTFail("Expected the stream to be refused")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
        } catch {
            XCTFail("Expected IndeRunException, got \(error)")
        }
    }

    func testFallsBackBeforeAnyContentIsDelivered() async throws {
        let registry = ProviderRegistry()
        let failing = MockStreamProvider(
            id: "p1_failing",
            script: [],
            throwAfterScript: createUnavailable(message: "boom")
        )
        let healthy = MockStreamProvider(id: "p2_healthy", script: [
            .init(.delta(text: "second")),
            .init(.done(finalText: "second"))
        ])
        try registry.register(failing)
        try registry.register(healthy)

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.last?.payload?.outcome, .completed)
        XCTAssertEqual(events.last?.payload?.finalText, "second")
        XCTAssertEqual(failing.callCount, 1)
        XCTAssertEqual(healthy.callCount, 1)
    }

    func testDoesNotFallBackOnceContentHasBeenDelivered() async throws {
        let registry = ProviderRegistry()
        let committing = MockStreamProvider(
            id: "p1_committing",
            script: [.init(.delta(text: "partial"))],
            throwAfterScript: createUnavailable(message: "died mid-stream")
        )
        let other = MockStreamProvider(id: "p2_other", script: [.init(.done(finalText: "unused"))])
        try registry.register(committing)
        try registry.register(other)

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.map { $0.type }, ["content_delta", "terminal"])
        XCTAssertEqual(events.last?.payload?.outcome, .error)
        XCTAssertEqual(events.last?.payload?.partialText, "partial")
        // Splicing a second provider's text onto the first provider's partial
        // output would be undetectable to the caller, so it must not happen.
        XCTAssertEqual(other.callCount, 0)
    }

    func testProducesExactlyOneCancelledTerminalAndStopsDeltas() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [
            .init(.delta(text: "one")),
            // Held until the consumer's cancel has landed, so "stops deltas" is
            // a real ordering guarantee rather than a wall-clock head start.
            .init(.delta(text: "two"), waitsForCancellation: true),
            .init(.done(finalText: "one two"))
        ]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let run = try await engine.stream(request: makeRequest())

        var events: [StreamEvent] = []
        for try await event in run.events {
            events.append(event)
            if event.type == "content_delta" {
                run.cancel(reason: "user stopped")
                // Repeated and concurrent cancels must stay idempotent.
                run.cancel(reason: "ignored")
            }
        }

        XCTAssertEqual(events.filter { $0.type == "terminal" }.count, 1)
        XCTAssertEqual(events.last?.payload?.outcome, .cancelled)
        XCTAssertEqual(events.last?.payload?.partialText, "one")
        XCTAssertEqual(events.last?.payload?.reason, "user stopped")
    }

    func testCancellationBeforeTheFirstAttemptForeclosesEveryProvider() async throws {
        let registry = ProviderRegistry()
        let provider = MockStreamProvider(id: "p1", script: [
            .init(.done(finalText: "never"), delayMs: 40)
        ])
        try registry.register(provider)

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let run = try await engine.stream(request: makeRequest())
        run.cancel(reason: "immediate")
        let events = try await drain(run)

        XCTAssertEqual(events.last?.payload?.outcome, .cancelled)
        XCTAssertEqual(events.last?.payload?.partialText, "")
    }

    func testReportsAnErrorWhenEveryProviderFailsBeforeCommitting() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(
            id: "p1", script: [], throwAfterScript: createUnavailable(message: "boom")
        ))
        try registry.register(MockStreamProvider(
            id: "p2", script: [], throwAfterScript: createUnavailable(message: "boom")
        ))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.last?.payload?.outcome, .error)
        XCTAssertEqual(events.last?.payload?.error?.errorClass, .Unavailable)
    }

    func testTreatsAStreamThatEndsWithoutATerminalEventAsAProviderFault() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [.init(.delta(text: "a"))]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.last?.payload?.outcome, .error)
        XCTAssertEqual(events.last?.payload?.partialText, "a")
    }

    func testAProviderReportedFailureEventBehavesLikeAThrow() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [
            .init(.failure(error: createRateLimited(message: "slow down")))
        ]))
        try registry.register(MockStreamProvider(id: "p2", script: [
            .init(.done(finalText: "recovered"))
        ]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())
        let events = try await drain(try await engine.stream(request: makeRequest()))

        XCTAssertEqual(events.last?.payload?.outcome, .completed)
        XCTAssertEqual(events.last?.payload?.finalText, "recovered")
    }

    func testStillTerminatesWhenTheEngineIsReleased() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockStreamProvider(id: "p1", script: [
            .init(.delta(text: "one"), delayMs: 10),
            .init(.done(finalText: "one"), delayMs: 10)
        ]))

        // The caller keeps only the StreamRun; a stream created from a temporary
        // engine must still produce its terminal event.
        var engine: IndeRun? = IndeRun(registry: registry, hostServices: makeHost())
        let run = try await engine!.stream(request: makeRequest())
        weak var released = engine
        engine = nil

        let events = try await drain(run)

        XCTAssertEqual(events.last?.payload?.outcome, .completed)
        XCTAssertEqual(events.last?.payload?.finalText, "one")
        // The run held the engine while it needed it, and let go afterwards.
        XCTAssertNil(released)
    }

    func testRunAndStreamMayResolveToDifferentProviderChains() async throws {
        let registry = ProviderRegistry()
        try registry.register(MockProvider(id: "a_run_only", type: .local))
        try registry.register(MockStreamProvider(id: "b_streaming", script: [
            .init(.done(finalText: "streamed"))
        ]))

        let engine = IndeRun(registry: registry, hostServices: makeHost())

        let result = try await engine.run(request: makeRequest())
        XCTAssertEqual(result.telemetry.providerUsed, "a_run_only")

        let run = try await engine.stream(request: makeRequest())
        XCTAssertEqual(run.handle.providerId, "b_streaming")
    }
}

// MARK: - OpenAI Streaming

/// Streaming HTTP host service that replays a scripted body, so the OpenAI
/// adapter's event mapping can be exercised without a network.
final class MockStreamingHttpClientService: HttpStreamingClientService, @unchecked Sendable {
    struct Script: @unchecked Sendable {
        var status: Int = 200
        var statusText: String = "OK"
        var headers: [String: String] = ["content-type": "text/event-stream"]
        var chunks: [String] = []
        var error: Error?
    }

    private let lock = NSLock()
    private let script: Script
    private var recorded: [HttpRequest] = []

    init(script: Script) {
        self.script = script
    }

    var requests: [HttpRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(request: HttpRequest) async throws -> HttpStreamResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()

        if let error = script.error { throw error }

        let chunks = script.chunks
        return HttpStreamResponse(
            status: script.status,
            statusText: script.statusText,
            headers: script.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(Data(chunk.utf8))
                }
                continuation.finish()
            }
        )
    }
}

final class OpenAIStreamingTests: XCTestCase {
    private struct TranscriptCase: Decodable {
        let name: String
        let description: String
        let sse: String
        let expected: [ExpectedEvent]
    }

    private struct ExpectedEvent: Decodable {
        let kind: String
        let text: String?
        let finalText: String?
        let finishReason: FinishReason?
        let usage: ExpectedUsage?
        let errorClass: ErrorClass?
        let message: String?
    }

    private struct ExpectedUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
    }

    private struct Fixture: Decodable {
        let cases: [TranscriptCase]
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/streaming/openai-responses-transcript.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func makeProvider() -> OpenAIProvider {
        OpenAIProvider(options: OpenAIProviderOptions(
            model: "gpt-5.2",
            endpointURL: "https://proxy.test/v1/responses"
        ))
    }

    private func makeHost(streaming: MockStreamingHttpClientService?) async -> HostServices {
        let storage = MockSecureStorageService()
        await storage.setSecret(slotId: "openai_default", secret: "sk-test")
        return HostServices(
            connectivity: MockConnectivityService(),
            secureStorage: storage,
            clock: MockClockService(),
            // capabilities() probes endpoint reachability over the unary client
            // before it reports anything about streaming.
            httpClient: MockHttpClientService(responses: [
                .success(HttpResponse(body: "{}", headers: [:], status: 200, statusText: "OK"))
            ]),
            streamingHttpClient: streaming
        )
    }

    private func makeRequest() -> TaskRequest {
        TaskRequest(
            task: TaskDescriptor(kind: .textToText),
            prompt: "Hello",
            authContextRef: "openai_default"
        )
    }

    private func collect(
        provider: OpenAIProvider,
        host: HostServices
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        let context = ProviderStreamContext(
            runId: "run-1",
            hostServices: host,
            cancellation: StreamCancellationToken()
        )
        for try await event in provider.stream(request: makeRequest(), context: context) {
            events.append(event)
        }
        return events
    }

    func testDeclaresStreamingAndATokenStreamingStyle() {
        let descriptor = makeProvider().describe()
        XCTAssertTrue(descriptor.supports.streaming)
        XCTAssertEqual(descriptor.streamingStyle, .tokens)
        XCTAssertEqual(descriptor.cancel, .hard)
    }

    func testReportsStreamingUnavailableWhenTheHostCannotStream() async {
        let host = await makeHost(streaming: nil)
        let capabilities = await makeProvider().capabilities(host: host)

        XCTAssertEqual(capabilities.streamingAvailable, false)
        XCTAssertEqual(
            capabilities.streamingUnavailableReason,
            "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires."
        )
    }

    func testAsksTheEndpointToStreamAndAuthenticatesWithTheResolvedCredential() async throws {
        let client = MockStreamingHttpClientService(script: .init(
            chunks: ["data: {\"type\":\"response.completed\",\"response\":{\"output_text\":\"hi\"}}\n\n"]
        ))
        let host = await makeHost(streaming: client)
        _ = try await collect(provider: makeProvider(), host: host)

        let sent = try XCTUnwrap(client.requests.first)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data((sent.body ?? "").utf8)) as? [String: Any]
        )
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "gpt-5.2")
        XCTAssertEqual(sent.headers?["Authorization"], "Bearer sk-test")
        XCTAssertEqual(sent.headers?["Accept"], "text/event-stream")
    }

    func testMatchesTheSharedTranscriptVectors() async throws {
        for transcript in try loadFixture().cases {
            let host = await makeHost(
                streaming: MockStreamingHttpClientService(script: .init(chunks: [transcript.sse]))
            )
            let events = try await collect(provider: makeProvider(), host: host)
            let label = "\(transcript.name): \(transcript.description)"

            XCTAssertEqual(events.count, transcript.expected.count, label)
            for (event, expected) in zip(events, transcript.expected) {
                switch (event, expected.kind) {
                case let (.delta(text), "delta"):
                    XCTAssertEqual(text, expected.text, label)

                case let (.done(finalText, finishReason, usage), "done"):
                    XCTAssertEqual(finalText, expected.finalText, label)
                    XCTAssertEqual(finishReason, expected.finishReason, label)
                    XCTAssertEqual(usage?.totalTokens, expected.usage?.totalTokens, label)

                case let (.failure(error), "error"):
                    let exception = try XCTUnwrap(error as? IndeRunException, label)
                    XCTAssertEqual(exception.errorClass, expected.errorClass, label)
                    XCTAssertEqual(exception.message, expected.message, label)

                default:
                    XCTFail("Unexpected event \(event) for expected kind \(expected.kind) in \(label)")
                }
            }
        }
    }

    func testIsUnaffectedByHowTheEventStreamIsChunked() async throws {
        let transcript = try loadFixture().cases[0]
        let client = MockStreamingHttpClientService(
            script: .init(chunks: transcript.sse.map { String($0) })
        )
        let host = await makeHost(streaming: client)

        let events = try await collect(provider: makeProvider(), host: host)

        XCTAssertEqual(events.count, transcript.expected.count)
    }

    func testClassifiesANonSuccessResponseBeforeReadingTheBodyAsAnEventStream() async throws {
        let client = MockStreamingHttpClientService(script: .init(
            status: 429,
            statusText: "Too Many Requests",
            headers: ["retry-after": "3"],
            chunks: ["{\"error\":{\"message\":\"Rate limit reached\"}}"]
        ))
        let host = await makeHost(streaming: client)

        do {
            _ = try await collect(provider: makeProvider(), host: host)
            XCTFail("Expected the stream to fail")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .RateLimited)
            XCTAssertEqual(error.retryAfterMs, 3000)
        }
    }

    func testRefusesToStreamWhenTheHostHasNoStreamingClient() async throws {
        let host = await makeHost(streaming: nil)

        do {
            _ = try await collect(provider: makeProvider(), host: host)
            XCTFail("Expected the stream to fail")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
        }
    }
}
