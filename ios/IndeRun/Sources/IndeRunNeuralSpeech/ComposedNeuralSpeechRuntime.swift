import Foundation
import IndeRunContracts

/// What the composed runtimes of `IndeRunOnnxProviders` and `IndeRunCoreAIProviders` share: the
/// `limits.memBytes` refusal and the stream that wraps one sentence's synthesis.
package enum ComposedNeuralSpeechRuntime {
    /// The refusal reason when the package's `limits.memBytes` exceeds the device memory
    /// (`deviceMemoryBytes`, default `ProcessInfo.physicalMemory`); `nil` when it fits or declares none.
    package static func memoryRefusal(_ modelPackage: ModelPackage, deviceMemoryBytes: (@Sendable () -> UInt64)?) -> String? {
        guard let needed = modelPackage.limits?.memBytes, needed > 0 else { return nil }
        let device = deviceMemoryBytes?() ?? ProcessInfo.processInfo.physicalMemory
        guard UInt64(needed) > device else { return nil }
        return "insufficient memory: package needs \(needed) bytes, device has \(device) bytes"
    }

    /// Runs `body` as one sentence's stream: it finishes when `body` returns, cancelling the consumer
    /// cancels `body`, and a cancelled `body` ends the stream without an error.
    package static func stream(
        _ body: @escaping @Sendable (AsyncThrowingStream<PcmChunk, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<PcmChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension NeuralSpeechRuntimeError {
    /// What a closed runtime throws from `synthesize` (see ``NeuralSpeechRuntime/close()``).
    package static var runtimeClosed: NeuralSpeechRuntimeError {
        NeuralSpeechRuntimeError(kind: .unavailable, message: "runtime closed", code: "runtime_closed")
    }
}

/// The `close()` machinery the composed runtimes share. Executors are created through
/// ``guarded(make:)``, so every graph call is counted: once closed, a new call fails with
/// ``NeuralSpeechRuntimeError/runtimeClosed`` (a running synthesis ends at its next graph
/// boundary), and ``close()`` closes the executors only after the calls in flight have returned.
/// Work that runs outside a graph call, such as a Core AI specialization, joins the same count
/// through ``cancellingOnClose(_:)``.
package final class SpeechRuntimeLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var inFlight = 0
    /// Cancels each piece of ``cancellingOnClose(_:)`` work in flight, by id.
    private var cancels: [Int: @Sendable () -> Void] = [:]
    private var nextWorkId = 0
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var executors: [any SpeechGraphExecutor] = []
    private var closing: Task<Void, Never>?

    package init() {}

    package var isClosed: Bool { lock.withLock { closed } }

    /// Creates an executor and registers it, or returns `nil` when already closed: nothing is built
    /// after `close()`.
    package func guarded(make: () -> (any SpeechGraphExecutor)?) -> (any SpeechGraphExecutor)? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let executor = make() else { return nil }
        executors.append(executor)
        return GuardedExecutor(inner: executor, lifecycle: self)
    }

    package func close() async {
        let task: Task<Void, Never> = lock.withLock {
            if let closing { return closing }
            closed = true
            let pending = Array(cancels.values)
            let task = Task { [self] in
                for cancel in pending { cancel() }
                await drain()
                let all = lock.withLock { executors }
                for executor in all { await executor.close() }
            }
            closing = task
            return task
        }
        await task.value
    }

    /// Runs `body` as work `close()` waits for, like a graph call in flight, and cancels when it
    /// begins. Returns `nil` without running `body` once closed. Cancelling the caller cancels `body`.
    package func cancellingOnClose<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
        let started: (id: Int, task: Task<T, Never>)? = lock.withLock {
            guard !closed else { return nil }
            inFlight += 1
            let id = nextWorkId
            nextWorkId += 1
            let task = Task { await body() }
            cancels[id] = { task.cancel() }
            return (id, task)
        }
        guard let started else { return nil }
        let result = await withTaskCancellationHandler {
            await started.task.value
        } onCancel: {
            started.task.cancel()
        }
        lock.withLock { cancels[started.id] = nil }
        leave()
        return result
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if inFlight == 0 { return true }
                drained.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    fileprivate func enter() throws {
        try lock.withLock {
            if closed { throw NeuralSpeechRuntimeError.runtimeClosed }
            inFlight += 1
        }
    }

    fileprivate func leave() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            inFlight -= 1
            guard inFlight == 0 else { return [] }
            defer { drained = [] }
            return drained
        }
        for continuation in waiting { continuation.resume() }
    }

    private struct GuardedExecutor: SpeechGraphExecutor {
        let inner: any SpeechGraphExecutor
        let lifecycle: SpeechRuntimeLifecycle

        func load(graphs: [String: String]) async throws {
            try lifecycle.enter()
            defer { lifecycle.leave() }
            try await inner.load(graphs: graphs)
        }

        func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
            try lifecycle.enter()
            defer { lifecycle.leave() }
            return try await inner.run(role: role, inputs: inputs)
        }

        func close() async {
            await inner.close()
        }
    }
}
