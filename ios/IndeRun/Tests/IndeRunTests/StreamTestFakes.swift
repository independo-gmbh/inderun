import XCTest
import IndeRunContracts
@testable import IndeRunCore

// MARK: - Mode 2 test fakes

/// Fakes shared by `StreamConformanceTests`, which drives the cross-SDK catalog,
/// and `StreamOrchestrationTests`, which keeps the Apple-specific coverage.

/// Scripted streaming provider mirroring `createFakeStreamProvider` in the Web
/// SDK's engine.stream tests, so both platforms are held to the same scenarios.
final class MockStreamProvider: StreamingProviderAdapter, @unchecked Sendable {
    struct Step {
        let event: ProviderStreamEvent?
        let delayMs: UInt64
        /// Blocks until the run has actually been cancelled and then ends without
        /// emitting, so tests that cancel mid-stream do not race a fixed delay.
        let waitsForCancellation: Bool

        init(_ event: ProviderStreamEvent, delayMs: UInt64 = 0) {
            self.event = event
            self.delayMs = delayMs
            self.waitsForCancellation = false
        }

        private init() {
            self.event = nil
            self.delayMs = 0
            self.waitsForCancellation = true
        }

        static let waitForCancellation = Step()
    }

    let id: String
    let script: [Step]
    let throwAfterScript: Error?
    let throwImmediately: Error?
    let declaresStreaming: Bool
    let type: ProviderDescriptor.ProviderType
    let streamingAvailable: Bool?
    let streamingUnavailableReason: String?
    private let lock = NSLock()
    private var attempts = 0
    private var entered = false
    private var interrupted = false

    init(
        id: String,
        script: [Step] = [],
        throwAfterScript: Error? = nil,
        throwImmediately: Error? = nil,
        declaresStreaming: Bool = true,
        type: ProviderDescriptor.ProviderType = .local,
        streamingAvailable: Bool? = nil,
        streamingUnavailableReason: String? = nil
    ) {
        self.id = id
        self.script = script
        self.throwAfterScript = throwAfterScript
        self.throwImmediately = throwImmediately
        self.declaresStreaming = declaresStreaming
        self.type = type
        self.streamingAvailable = streamingAvailable
        self.streamingUnavailableReason = streamingUnavailableReason
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    /// True once the provider observed its own cancellation, rather than merely
    /// being abandoned.
    var wasInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    private var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    /// Waits until this provider's stream body has actually begun producing.
    ///
    /// What separates "cancel during a pre-commit attempt" from "cancel before the
    /// first attempt" is exactly this moment, so the tests wait for it instead of
    /// guessing at a delay. Bounded, so a broken path fails rather than hangs.
    func waitUntilEntered() async {
        for _ in 0 ..< 500 where !hasEntered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: type,
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
        ProviderDynamicCapabilities(
            available: true,
            streamingAvailable: streamingAvailable,
            streamingUnavailableReason: streamingUnavailableReason
        )
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
            Task { [script, throwAfterScript, throwImmediately] in
                self.markEntered()
                if let throwImmediately {
                    continuation.finish(throwing: throwImmediately)
                    return
                }
                for step in script {
                    if step.waitsForCancellation {
                        // Bounded so a broken cancellation path fails the test
                        // instead of hanging it; the loop exits the moment
                        // cancellation is observed.
                        for _ in 0 ..< 500 where !context.cancellation.isCancelled {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                        self.markInterrupted()
                        continuation.finish()
                        return
                    }
                    if step.delayMs > 0 {
                        try? await Task.sleep(nanoseconds: step.delayMs * 1_000_000)
                    }
                    if context.cancellation.isCancelled {
                        self.markInterrupted()
                        continuation.finish()
                        return
                    }
                    if let event = step.event {
                        continuation.yield(event)
                    }
                }
                if let throwAfterScript {
                    continuation.finish(throwing: throwAfterScript)
                    return
                }
                continuation.finish()
            }
        }
    }

    private func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }

    private func markInterrupted() {
        lock.lock()
        interrupted = true
        lock.unlock()
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

