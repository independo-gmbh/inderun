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
