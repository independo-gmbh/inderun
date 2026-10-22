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
        /// Calls `context.commit()` and records what it returned.
        let commits: Bool
        /// Calls the commit this provider kept from its own, earlier attempt -- a late callback
        /// from an attempt the run has already left -- and records the result as its own.
        let callsKeptCommitOf: MockStreamProvider?

        init(_ event: ProviderStreamEvent, delayMs: UInt64 = 0) {
            self.event = event
            self.delayMs = delayMs
            self.waitsForCancellation = false
            self.commits = false
            self.callsKeptCommitOf = nil
        }

        private init(waitsForCancellation: Bool, commits: Bool, callsKeptCommitOf: MockStreamProvider? = nil) {
            self.event = nil
            self.delayMs = 0
            self.waitsForCancellation = waitsForCancellation
            self.commits = commits
            self.callsKeptCommitOf = callsKeptCommitOf
        }

        static func callKeptCommit(of provider: MockStreamProvider) -> Step {
            Step(waitsForCancellation: false, commits: false, callsKeptCommitOf: provider)
        }

        static let waitForCancellation = Step(waitsForCancellation: true, commits: false)
        /// A commit step directly after `waitForCancellation` runs once the cancellation has
        /// been observed, which is how a provider that asks to commit too late is modelled.
        static let commit = Step(waitsForCancellation: false, commits: true)
    }

    let id: String
    let script: [Step]
    let throwAfterScript: Error?
    let throwImmediately: Error?
    let declaresStreaming: Bool
    let type: ProviderType
    let streamingAvailable: Bool?
    let streamingUnavailableReason: String?
    let task: TaskKind
    /// Keeps each attempt's context for `callKeptCommit()`. Off by default: the context's
    /// commit retains the engine, which `testStillTerminatesWhenTheEngineIsReleased` must see go.
    let keepsCommit: Bool
    private let lock = NSLock()
    private var attempts = 0
    private var entered = false
    private var interrupted = false
    private var recordedCommitResults: [Bool] = []
    private var keptContext: ProviderStreamContext?

    init(
        id: String,
        script: [Step] = [],
        throwAfterScript: Error? = nil,
        throwImmediately: Error? = nil,
        declaresStreaming: Bool = true,
        type: ProviderType = .local,
        streamingAvailable: Bool? = nil,
        streamingUnavailableReason: String? = nil,
        task: TaskKind = .textToText,
        keepsCommit: Bool = false
    ) {
        self.id = id
        self.script = script
        self.throwAfterScript = throwAfterScript
        self.throwImmediately = throwImmediately
        self.declaresStreaming = declaresStreaming
        self.type = type
        self.streamingAvailable = streamingAvailable
        self.streamingUnavailableReason = streamingUnavailableReason
        self.task = task
        self.keepsCommit = keepsCommit
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

    /// What each `context.commit()` call returned, in call order.
    var commitResults: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommitResults
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

    /// Waits until this provider has called `context.commit()` for the first time.
    /// Bounded, so a broken path fails rather than hangs.
    func waitUntilCommitted() async {
        for _ in 0 ..< 500 where commitResults.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A `text_to_speech` fake adds a speech capability with playback delivery in de-AT, so
    /// the planner routes speech requests to it.
    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: type,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true,
                streaming: declaresStreaming,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .soft,
            tasks: [task.rawValue],
            taskCapabilities: task == .textToSpeech
                ? [
                    ProviderTaskCapability(
                        kind: task.rawValue,
                        inputs: [.text],
                        interaction: ProviderTaskInteraction(run: true, stream: declaresStreaming),
                        cancel: .soft,
                        outputs: [ProviderTaskOutput(delivery: .playback)],
                        locales: ["de-AT"]
                    )
                ]
                : nil
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
            output: TaskOutput(text: "unused"),
            finishReason: FinishReason.stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    /// Calls the `context.commit()` of this provider's latest attempt and records the result.
    func callKeptCommit() {
        lock.lock()
        let context = keptContext
        lock.unlock()
        if let context { recordCommit(context.commit()) }
    }

    func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        lock.lock()
        attempts += 1
        if keepsCommit { keptContext = context }
        lock.unlock()

        return AsyncThrowingStream { continuation in
            Task { [script, throwAfterScript, throwImmediately] in
                self.markEntered()
                if let throwImmediately {
                    continuation.finish(throwing: throwImmediately)
                    return
                }
                for (index, step) in script.enumerated() {
                    if step.waitsForCancellation {
                        // Bounded so a broken cancellation path fails the test
                        // instead of hanging it; the loop exits the moment
                        // cancellation is observed.
                        for _ in 0 ..< 500 where !context.cancellation.isCancelled {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                        self.markInterrupted()
                        for late in script[(index + 1)...] where late.commits {
                            self.recordCommit(context.commit())
                        }
                        continuation.finish()
                        return
                    }
                    if step.commits {
                        self.recordCommit(context.commit())
                        continue
                    }
                    if let other = step.callsKeptCommitOf {
                        other.callKeptCommit()
                        continue
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

    private func recordCommit(_ result: Bool) {
        lock.lock()
        recordedCommitResults.append(result)
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
            supports: ProviderSupports(
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
            output: TaskOutput(text: "unused"),
            finishReason: FinishReason.stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }
}

/// The request the `non_text_outputs` conformance cases stream: speech 'Hallo' in de-AT,
/// played back on the device.
func makeSpeechRequest(delivery: OutputDeliveryRequest = OutputDeliveryRequest(destinationRef: nil, mediaTypes: nil, mode: .playback)) -> TaskRequest {
    TaskRequest(
        task: TaskDescriptor(kind: .textToSpeech),
        constraints: TaskRequestConstraints(privacy: .localRequired),
        speech: SpeechInput(locale: "de-AT", localeMatch: nil, text: "Hallo", voice: nil),
        delivery: delivery
    )
}
