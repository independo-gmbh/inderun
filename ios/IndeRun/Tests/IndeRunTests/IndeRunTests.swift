import XCTest
import IndeRunContracts
import IndeRunCore
@testable import IndeRunAppleProviders
@testable import IndeRunOpenAIProviders
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
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
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
    
    func testRoutingOnDeviceSuccess() async throws {
        let p1 = MockProvider(id: "local_p", type: .local)
        try registry.register(p1)
        
        let request = TaskRequest(
            prompt: "Test on-device",
            policy: Policy(execution: .onDevice)
        )
        
        let result = try await inderun.run(request: request)
        XCTAssertEqual(result.output.text, "Hello from local_p")
        XCTAssertEqual(result.telemetry.providerUsed, "local_p")
        
        XCTAssertEqual(telemetry.events.count, 2)
        XCTAssertEqual(telemetry.events[0].type, .routeDecided)
        XCTAssertEqual(telemetry.events[1].type, .attemptSucceeded)
    }
    
    func testRoutingOnDeviceMismatch() async throws {
        let request = TaskRequest(
            prompt: "Test missing device",
            policy: Policy(execution: .onDevice)
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
    
    func testRoutingCloudOffline() async throws {
        let p1 = MockProvider(id: "cloud_p", type: .cloud)
        try registry.register(p1)
        
        connectivity.online = false
        
        let request = TaskRequest(
            prompt: "Test offline cloud",
            policy: Policy(execution: .cloud)
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
            policy: Policy(execution: .onDevice)
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
            policy: Policy(execution: .cloud),
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
            policy: Policy(execution: .cloud)
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
          "policy": { "execution": "cloud" },
          "authContextRef": "openai/main"
        }
        """
        let request = try decoder.decode(TaskRequest.self, from: Data(requestJSON.utf8))
        XCTAssertEqual(request.schemaVersion, .the10)
        XCTAssertEqual(request.task.kind, .textToText)
        XCTAssertEqual(request.policy.execution, .cloud)
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
        XCTAssertEqual(result.finishReason, .stop)
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
            policy: Policy(execution: .onDevice)
        )

        let result = try await provider.run(
            request: request,
            context: RunContext(runId: "run_apple", hostServices: hostServices)
        )

        XCTAssertEqual(result.runId, "run_apple")
        XCTAssertEqual(result.output.text, "Bonjour")
        XCTAssertEqual(result.finishReason, .stop)
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
            policy: Policy(execution: .onDevice)
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
        let request = TaskRequest(prompt: "Hello", policy: Policy(execution: .onDevice))

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
        let request = TaskRequest(prompt: "Hello", policy: Policy(execution: .onDevice))

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
            policy: Policy(execution: .cloud)
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
        XCTAssertEqual(result.finishReason, .stop)
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
            policy: Policy(execution: .cloud)
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
        let request = TaskRequest(prompt: "Hello", policy: Policy(execution: .cloud))

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
                request: TaskRequest(prompt: "Hello", policy: Policy(execution: .cloud)),
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
                request: TaskRequest(prompt: "Hello", policy: Policy(execution: .cloud)),
                context: RunContext(runId: "run_cancel", hostServices: hostServices)
            )
            XCTFail("Should have thrown Unavailable")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
        } catch {
            XCTFail("Expected IndeRunException")
        }
    }

    func testAppleCloudProviderRegistryFactoryRegistersOpenAIProvider() throws {
        let registry = try AppleCloudProviderRegistryFactory.makeOpenAIRegistry(
            options: OpenAIProviderOptions(model: "gpt-5.2", auth: .none)
        )

        XCTAssertNotNil(registry.get(id: "openai"))
        XCTAssertEqual(registry.list().count, 1)
    }
}
