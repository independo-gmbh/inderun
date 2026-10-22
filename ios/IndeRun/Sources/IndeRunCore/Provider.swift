import Foundation
import IndeRunContracts

// ProviderDescriptor, ProviderDynamicCapabilities and ProviderCapabilitySnapshot are
// generated from contracts/schemas/provider-*.schema.json into IndeRunContracts, which
// this module re-exports. The convenience initializers live in
// IndeRunContracts/Compatibility.swift.

// MARK: - RunContext
public struct RunContext: Sendable {
    public let runId: String
    public let hostServices: HostServices
    /// The voice the route plan bound this provider to for a speech task: provider-neutral
    /// traits the provider must honour when it picks the voice that speaks. `nil` for tasks
    /// without a voice and for providers that do not list their voices, which then choose
    /// under the same rule (ADR 016 §4). The engine has re-checked it against the request's
    /// privacy policy immediately before the attempt.
    public let voice: ProviderVoice?
    /// Where the provider writes retrievable media for an `artifact` request (ADR 017). The
    /// engine holds the bytes; the provider returns the reference `finish()` gives it in an
    /// `artifact` output. Finishing commits the run. Artifacts this attempt does not return,
    /// or that a failed or cancelled attempt wrote, are discarded by the engine.
    public let artifacts: any ArtifactSink
    private let commitHandler: @Sendable () -> Bool

    /// - Parameters:
    ///   - artifacts: Where the provider writes artifacts. The engine supplies the attempt's
    ///     view of its own store; when `nil`, a context built elsewhere writes into a
    ///     standalone ``ArtifactStore`` of its own, handing over under `commit`.
    ///   - commit: What ``commit()`` does. The engine supplies its own; a context built
    ///     elsewhere (e.g. to call a provider directly) commits unless the calling task is
    ///     cancelled, which is the engine's rule for `run()`.
    public init(
        runId: String,
        hostServices: HostServices,
        voice: ProviderVoice? = nil,
        artifacts: (any ArtifactSink)? = nil,
        commit: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) {
        self.runId = runId
        self.hostServices = hostServices
        self.voice = voice
        self.artifacts = artifacts ?? ArtifactStore().attempt(commit: commit)
        self.commitHandler = commit
    }

    /// Commits the run to this provider. Call it immediately before the attempt's first
    /// externally observable effect -- for managed playback, no later than the first moment
    /// sound may reach the user. After commit, a failure ends the run instead of falling back
    /// to another provider, because a second provider would repeat what the user may already
    /// have heard.
    ///
    /// Returns `false` when the run can no longer commit (the calling task was cancelled)
    /// and when this attempt is over, e.g. a late callback after the engine fell back to
    /// another provider; the provider must then not start the effect and should end the
    /// attempt. Idempotent: calling it again after a successful commit returns `true`.
    ///
    /// Providers whose output is only delivered at the end (text from `run()`) need not call
    /// it.
    public func commit() -> Bool {
        commitHandler()
    }
}

// MARK: - ProviderAdapter Protocol

/// Pluggable execution adapter wrapping a specific model runtime (system
/// frameworks, local runtimes, or cloud APIs) behind normalized IndeRun APIs.
public protocol ProviderAdapter: Sendable {
    /// Returns the static descriptor used by routing to select candidates.
    func describe() -> ProviderDescriptor
    /// Reports whether the provider can execute on the current host right now.
    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities
    /// Executes a Mode 1 (request/response) task, throwing `IndeRunException` on failure.
    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult
}
