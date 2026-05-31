import XCTest
import IndeRunContracts
import IndeRunCore
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
}
