import Foundation
import IndeRunContracts

// MARK: - Cancellation

/// Caller-driven cancellation signal for a Mode 2 stream, shared between the
/// engine and the provider adapter driving the run.
///
/// This is the Swift analogue of the Web SDK's `AbortSignal`. Swift's own task
/// cancellation is not sufficient on its own: a provider is free to produce its
/// events from a `Task` it created itself, which does not inherit cancellation
/// from the task consuming the stream. An explicit token gives every provider a
/// signal it can observe regardless of how it is structured, and gives the three
/// SDKs one shared cancellation model.
///
/// Cancelling is idempotent: only the first call records a reason and fires the
/// registered handlers.
public final class StreamCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationReason: String?
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// The reason passed to the first `cancel` call, when one was given.
    public var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationReason
    }

    /// Registers a handler invoked on cancellation. Fires immediately, on the
    /// calling thread, if cancellation already happened.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    /// Requests cancellation. Subsequent calls are no-ops.
    public func cancel(reason: String? = nil) {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        cancellationReason = reason
        let pending = handlers
        handlers = []
        lock.unlock()

        for handler in pending {
            handler()
        }
    }
}

// MARK: - Provider streaming contract

/// Execution context passed to `StreamingProviderAdapter.stream`. Extends
/// ``RunContext`` with the caller-driven cancellation signal; the engine owns the
/// token, so providers never construct their own.
public struct ProviderStreamContext: Sendable {
    public let runId: String
    public let hostServices: HostServices
    /// Signals caller-driven cancellation of this stream. Providers declaring
    /// `cancel: .hard` should tear down their connection immediately; `.soft`
    /// providers may stop relaying without interrupting underlying work; `.none`
    /// providers may ignore it. The engine enforces the caller-visible
    /// cancellation guarantee regardless of what the provider does.
    public let cancellation: StreamCancellationToken

    public init(runId: String, hostServices: HostServices, cancellation: StreamCancellationToken) {
        self.runId = runId
        self.hostServices = hostServices
        self.cancellation = cancellation
    }
}

/// A raw, provider-shaped streaming event.
///
/// Intentionally distinct from the canonical `StreamEvent` contract: providers
/// emit provider-shaped deltas here and the engine's Event Gate normalizes them,
/// keeping provider-specific mechanics from leaking through the public API.
public enum ProviderStreamEvent: Sendable {
    /// An incremental text increment since the previous content event.
    case delta(text: String)
    /// The full cumulative text produced so far, replacing what came before.
    case snapshot(text: String)
    /// Terminal success. `finishReason` and `usage` are reported when the
    /// provider exposes them.
    case done(finalText: String, finishReason: FinishReason? = nil, usage: TaskResultUsage? = nil)
    /// Terminal failure. Handled identically to the stream throwing.
    case failure(error: Error)
}

/// A ``ProviderAdapter`` that additionally supports Mode 2 streaming.
///
/// Streaming support is a separate protocol rather than an optional member so
/// that "declares streaming and actually implements it" is a conformance check
/// the router can make before planning a route, mirroring the Web SDK's
/// `typeof provider.stream === "function"` test.
public protocol StreamingProviderAdapter: ProviderAdapter {
    /// Executes a Mode 2 (streaming) task. The returned sequence must end with a
    /// `.done` or `.failure` event, or by throwing; ending without one is treated
    /// as a provider fault.
    func stream(request: TaskRequest, context: ProviderStreamContext)
        -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

// MARK: - Stream run handle

/// What `IndeRun.stream()` returns: the run's identity, its canonical event
/// sequence, and a cancel hook.
///
/// `events` terminates in exactly one terminal `StreamEvent`, and is single-use —
/// the underlying run is driven once, not restarted per consumer. `cancel` is
/// idempotent: repeated or concurrent calls produce exactly one `cancelled`
/// terminal outcome.
public struct StreamRun: Sendable {
    public let handle: StreamRunHandle
    public let events: AsyncThrowingStream<StreamEvent, Error>
    private let cancellation: @Sendable (String?) -> Void

    public init(
        handle: StreamRunHandle,
        events: AsyncThrowingStream<StreamEvent, Error>,
        cancel: @escaping @Sendable (String?) -> Void
    ) {
        self.handle = handle
        self.events = events
        cancellation = cancel
    }

    /// Cancels the run. Idempotent.
    public func cancel(reason: String? = nil) {
        cancellation(reason)
    }
}
