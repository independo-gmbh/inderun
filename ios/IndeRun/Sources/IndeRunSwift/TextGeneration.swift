import Foundation
import IndeRunCore
import IndeRunContracts

// The primary text API: `generateText` and `streamText`.
//
// Both are translation only. Each call compiles to exactly one canonical `TaskRequest`
// (`TextGenerationOptions.taskRequest()`) and calls `run` or `stream` on the `IndeRunApi`
// it extends, so routing, fallback, cancellation, credentials, telemetry, and error
// normalization are the engine's and identical to a direct call. Mirrors the Web SDK's
// `facade/text.ts`; the shared vectors in `contracts/fixtures/facade/` hold the two to the
// same translation. See `docs/architecture/api-layering.md`.

/// What a text call is about: a single prompt or a conversation.
public enum TextInput: Sendable {
    case prompt(String)
    case messages([Message])
}

/// Compact execution policy. Reuses the canonical enum values, so moving a call between
/// the facade and `run` never changes what a constraint means.
public struct TextExecutionOptions: Sendable {
    public var privacy: Privacy?
    public var cloud: Cloud?
    public var timeoutMs: Int?
    public var optimizeFor: OptimizeFor?

    public init(
        privacy: Privacy? = nil,
        cloud: Cloud? = nil,
        timeoutMs: Int? = nil,
        optimizeFor: OptimizeFor? = nil
    ) {
        self.privacy = privacy
        self.cloud = cloud
        self.timeoutMs = timeoutMs
        self.optimizeFor = optimizeFor
    }
}

/// Options for `generateText` and `streamText`.
public struct TextGenerationOptions: Sendable {
    public var input: TextInput
    /// Model profile to route within, as configured on the engine. `nil` or `"auto"`
    /// routes across every registered target. Never a vendor model id.
    public var model: String?
    /// Instructions sent as a leading `system` message.
    public var system: String?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var stop: [String]?
    public var seed: Int?
    public var execution: TextExecutionOptions?
    /// Secure-storage slot for provider credentials. Never a raw secret.
    public var authContextRef: String?
    public var telemetry: TaskRequestTelemetry?
    /// Fixes the run id, for correlation.
    public var requestId: String?

    public init(
        _ input: TextInput,
        model: String? = nil,
        system: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stop: [String]? = nil,
        seed: Int? = nil,
        execution: TextExecutionOptions? = nil,
        authContextRef: String? = nil,
        telemetry: TaskRequestTelemetry? = nil,
        requestId: String? = nil
    ) {
        self.input = input
        self.model = model
        self.system = system
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.seed = seed
        self.execution = execution
        self.authContextRef = authContextRef
        self.telemetry = telemetry
        self.requestId = requestId
    }

    /// The canonical `TaskRequest` a facade call compiles to.
    public func taskRequest() -> TaskRequest {
        var prompt: String?
        var messages: [Message]?
        switch input {
        case let .prompt(text) where system != nil:
            messages = [Message(role: .user, content: text)]
        case let .prompt(text):
            prompt = text
        case let .messages(list):
            messages = list
        }
        if let system {
            messages = [Message(role: .system, content: system)] + (messages ?? [])
        }

        let hasGeneration = maxOutputTokens != nil || temperature != nil || topP != nil
            || stop != nil || seed != nil
        let constraints = execution.flatMap { execution -> TaskRequestConstraints? in
            guard execution.privacy != nil || execution.cloud != nil || execution.timeoutMs != nil else {
                return nil
            }
            return TaskRequestConstraints(
                privacy: execution.privacy,
                cloud: execution.cloud,
                timeoutMs: execution.timeoutMs
            )
        }

        return TaskRequest(
            requestId: requestId,
            prompt: prompt,
            messages: messages,
            modelProfile: model == ModelProfiles.auto ? nil : model,
            generation: hasGeneration
                ? Generation(
                    maxOutputTokens: maxOutputTokens,
                    seed: seed,
                    stop: stop,
                    temperature: temperature,
                    topP: topP
                )
                : nil,
            constraints: constraints,
            preferences: execution?.optimizeFor.map { TaskRequestPreferences(optimizeFor: $0) },
            telemetry: telemetry,
            authContextRef: authContextRef
        )
    }
}

/// What `generateText` returns.
public struct GeneratedText: Sendable {
    public let text: String
    public let finishReason: FinishReason
    public let usage: TaskResultUsage?
    public let runId: String
    /// How the run played out; see `ExecutionProvenance`.
    public let provenance: ExecutionProvenance?
    /// The canonical result, for anything the summary above leaves out.
    public let taskResult: TaskResult
}

/// How a `streamText` run ended, when it did not fail.
public struct StreamedText: Sendable {
    /// The full text, or the partial text a cancelled run had delivered.
    public let text: String
    /// `.cancelled` when the run was cancelled; otherwise as the provider reported it.
    public let finishReason: FinishReason?
    public let usage: TaskResultUsage?
    public let runId: String
    public let provenance: ExecutionProvenance?
}

/// Thrown by `TextStream.textStream` when the provider replaces text it already delivered
/// with text that does not extend it, which an append-only text view cannot represent.
public struct TextStreamRetractedError: Error, Sendable, CustomStringConvertible {
    public let runId: String

    public var description: String {
        "Run \(runId) replaced text it had already delivered; read fullStream to render retractions."
    }
}

/// What `streamText` returns. The run is read once into a replay buffer, so `textStream`,
/// `fullStream`, and `result()` can each be consumed in any order without stalling the others.
public final class TextStream: Sendable {
    public let runId: String
    private let replay: EventReplay
    private let cancellation: @Sendable (String?) -> Void

    init(run: StreamRun) {
        runId = run.handle.runId
        replay = EventReplay()
        cancellation = { reason in run.cancel(reason: reason) }
        let replay = replay
        Task {
            do {
                // The terminal event is the last one a run delivers, so it settles everything;
                // a source that stays open after it (a bridge subscription, say) must not hold
                // the views back.
                for try await event in run.events {
                    await replay.push(event)
                    if event.type == "terminal" { break }
                }
                await replay.finish(throwing: nil)
            } catch {
                await replay.finish(throwing: error)
            }
        }
    }

    /// The canonical `StreamEvent` sequence, terminal included. Each access replays from the start.
    public var fullStream: AsyncThrowingStream<StreamEvent, Error> {
        let replay = replay
        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = 0
                do {
                    while let event = try await replay.event(at: index) {
                        continuation.yield(event)
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text increments, in order. Finishes when the run completes or is cancelled; throws the
    /// run's `IndeRunException` when it fails, and `TextStreamRetractedError` when delivered
    /// text is replaced (use `fullStream` to render retractions).
    public var textStream: AsyncThrowingStream<String, Error> {
        let events = fullStream
        let runId = runId
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                do {
                    for try await event in events {
                        switch event.type {
                        case "content_delta":
                            let delta = event.payload?.text ?? ""
                            text += delta
                            continuation.yield(delta)
                        case "content_snapshot":
                            let snapshot = event.payload?.text ?? ""
                            guard snapshot.hasPrefix(text) else {
                                throw TextStreamRetractedError(runId: runId)
                            }
                            let suffix = String(snapshot.dropFirst(text.count))
                            text = snapshot
                            if !suffix.isEmpty { continuation.yield(suffix) }
                        case "terminal":
                            _ = try settle(event, runId: runId)
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The run's ending: returns on completion or cancellation, throws the run's
    /// `IndeRunException` on failure.
    public func result() async throws -> StreamedText {
        var index = 0
        while let event = try await replay.event(at: index) {
            if event.type == "terminal" { return try settle(event, runId: runId) }
            index += 1
        }
        throw createInternal(message: "Run \(runId) ended without a terminal event.", runId: runId)
    }

    /// Cancels the run. Idempotent.
    public func cancel(reason: String? = nil) {
        cancellation(reason)
    }
}

private func settle(_ terminal: StreamEvent, runId: String) throws -> StreamedText {
    let payload = terminal.payload
    let usage = payload?.usage.map {
        TaskResultUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, totalTokens: $0.totalTokens)
    }
    switch payload?.outcome {
    case .some(.completed):
        return StreamedText(
            text: payload?.finalText ?? payload?.output?.text ?? "",
            finishReason: payload?.finishReason,
            usage: usage,
            runId: runId,
            provenance: payload?.provenance
        )
    case .some(.cancelled):
        return StreamedText(
            text: payload?.partialText ?? payload?.output?.text ?? "",
            finishReason: .cancelled,
            usage: nil,
            runId: runId,
            provenance: payload?.provenance
        )
    case .some(.error):
        let error = payload?.error
        throw IndeRunException(
            errorClass: error?.errorClass ?? .Internal,
            message: error?.message ?? "Run \(runId) failed.",
            runId: runId,
            providerId: error?.providerId,
            retryable: error?.retryable,
            retryAfterMs: error?.retryAfterMs,
            details: error?.details,
            provenance: payload?.provenance
        )
    case .none:
        throw createInternal(message: "Run \(runId) ended with a malformed terminal event.", runId: runId)
    }
}

/// Holds every event read from the single-use run so any number of readers can replay it.
private actor EventReplay {
    private var events: [StreamEvent] = []
    private var finished = false
    private var failure: Error?
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    func push(_ event: StreamEvent) {
        events.append(event)
        wake()
    }

    func finish(throwing error: Error?) {
        failure = error
        finished = true
        wake()
    }

    /// The event at `index`, waiting for it if the run has not produced it yet; `nil` once
    /// the run has ended without one. Throws `CancellationError` when the waiting task is
    /// cancelled, so a reader whose consumer went away does not stay parked on an idle run.
    func event(at index: Int) async throws -> StreamEvent? {
        while index >= events.count && !finished {
            try Task.checkCancellation()
            let waiter = nextWaiter
            nextWaiter += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    // Cancellation can land before the continuation is stored, when the
                    // handler below finds nothing to resume.
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[waiter] = continuation
                    }
                }
            } onCancel: {
                Task { await self.resumeCancelled(waiter) }
            }
        }
        if index < events.count { return events[index] }
        if let failure { throw failure }
        return nil
    }

    private func resumeCancelled(_ waiter: Int) {
        waiters.removeValue(forKey: waiter)?.resume()
    }

    private func wake() {
        let pending = waiters.values
        waiters = [:]
        pending.forEach { $0.resume() }
    }
}

public extension IndeRunApi {
    /// Generates text in one call: `run` over the canonical request. Not cancellable, for the
    /// same reason `run` is not; use `streamText` when cancellation matters.
    /// - Throws: Exactly what `run` throws.
    func generateText(_ options: TextGenerationOptions) async throws -> GeneratedText {
        let result = try await run(request: options.taskRequest())
        return GeneratedText(
            // A text run always produces text; `TaskOutput.text` is optional only because the
            // same type describes playback and artifacts (ADR 016).
            text: result.output.text ?? "",
            finishReason: result.finishReason,
            usage: result.usage,
            runId: result.runId,
            provenance: result.provenance,
            taskResult: result
        )
    }

    /// Streams text: `stream` over the canonical request. The run starts immediately.
    /// - Throws: Exactly what `stream` throws: validation and routing refusals, before there
    ///   is a run.
    func streamText(_ options: TextGenerationOptions) async throws -> TextStream {
        TextStream(run: try await stream(request: options.taskRequest()))
    }
}
