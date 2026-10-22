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

    public init(runId: String, hostServices: HostServices, voice: ProviderVoice? = nil) {
        self.runId = runId
        self.hostServices = hostServices
        self.voice = voice
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
