import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import IndeRunContracts
import IndeRunCore

/// Dynamic availability state for the Apple Foundation Models runtime.
///
/// This is intentionally smaller than Apple's native availability enum so the
/// provider can be unit tested without importing or executing FoundationModels.
public enum AppleFoundationModelsAvailability: Equatable, Sendable {
    /// The system language model is available for immediate execution.
    case available
    /// The system language model cannot currently run, with a developer-facing reason.
    case unavailable(reason: String)
}

/// Provider-neutral generation options supported by the Apple Mode-1 adapter.
///
/// Unsupported canonical hints, such as `topP`, `seed`, and `stop`, are ignored
/// by this provider rather than leaked into the public API.
struct AppleFoundationModelsGenerationOptions: Equatable, Sendable {
    let maxOutputTokens: Int?
    let temperature: Double?
}

/// Internal seam around Apple's FoundationModels API.
///
/// The production implementation calls `SystemLanguageModel` and
/// `LanguageModelSession`; tests inject a mock runtime so availability and error
/// mapping are deterministic on machines without Apple Intelligence support.
protocol AppleFoundationModelsRuntime: Sendable {
    /// Returns the current dynamic model availability.
    func availability() async -> AppleFoundationModelsAvailability

    /// Generates a single text response for a normalized prompt.
    ///
    /// - Parameters:
    ///   - prompt: The provider-normalized text prompt.
    ///   - options: Generation hints supported by the Apple adapter.
    /// - Returns: The generated text content.
    func respond(to prompt: String, options: AppleFoundationModelsGenerationOptions) async throws -> String

    /// Streams the response for a normalized prompt as **cumulative** text.
    ///
    /// Each element is the full text produced so far, not an increment, because
    /// that is what `LanguageModelSession.streamResponse(to:)` produces. Keeping
    /// the seam cumulative means the adapter never has to diff snapshots into
    /// deltas, and the descriptor can declare `streamingStyle: .snapshots`
    /// truthfully.
    ///
    /// - Parameters:
    ///   - prompt: The provider-normalized text prompt.
    ///   - options: Generation hints supported by the Apple adapter.
    /// - Returns: A stream of cumulative text snapshots.
    func streamResponse(
        to prompt: String,
        options: AppleFoundationModelsGenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

/// On-device text-to-text provider backed by Apple Foundation Models, supporting
/// both Mode 1 (`run`) and Mode 2 (`stream`).
///
/// The provider is deliberately not auto-registered. Apps opt in by registering
/// this adapter directly or by using `AppleProviderRegistryFactory`. Runtime
/// availability still depends on OS support, device eligibility, Apple
/// Intelligence enablement, and model readiness.
public final class AppleFoundationModelsProvider: StreamingProviderAdapter, Sendable {
    /// Stable provider id used in routing explanations and telemetry.
    public static let defaultId = "apple_foundation_models"

    private let id: String
    private let runtime: any AppleFoundationModelsRuntime

    /// Creates a provider backed by Apple's system Foundation Models runtime.
    ///
    /// - Parameter id: Provider identifier used in route explanations and telemetry.
    public convenience init(id: String = AppleFoundationModelsProvider.defaultId) {
        self.init(id: id, runtime: SystemAppleFoundationModelsRuntime())
    }

    init(id: String = AppleFoundationModelsProvider.defaultId, runtime: any AppleFoundationModelsRuntime) {
        self.id = id
        self.runtime = runtime
    }

    /// Returns static provider metadata used by the router before dynamic checks.
    public func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .systemService,
            streamingStyle: .snapshots,
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
            tasks: ["text_to_text"],
            privacy: ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice: false)
        )
    }

    /// Reports whether Apple's system language model is usable right now.
    ///
    /// Host services are accepted to satisfy the provider contract; this provider
    /// currently relies only on Apple's system model availability.
    ///
    /// `streamingAvailable` is deliberately left unset so the static
    /// `supports.streaming` declaration is inherited: unlike the HTTP-transport
    /// providers, nothing about the host can take streaming away here. Mode 1 and
    /// Mode 2 sit behind the same OS/device/model gate, so an unavailable system
    /// model already removes both.
    ///
    /// - Parameter host: Host services supplied by the engine.
    /// - Returns: A dynamic capability snapshot for route selection.
    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        let availability = await runtime.availability()
        return ProviderDynamicCapabilities(available: availability == .available)
    }

    /// Executes a normalized Mode-1 text-to-text request on the system model.
    ///
    /// Availability is checked again immediately before execution so a stale
    /// route decision maps to `CapabilityMismatch` instead of leaking native
    /// FoundationModels failures through the public API.
    ///
    /// - Parameters:
    ///   - request: Canonical IndeRun text-to-text request.
    ///   - context: Engine run context containing the run id and host services.
    /// - Returns: A normalized text result.
    /// - Throws: `IndeRunException` with `CapabilityMismatch` when the system
    ///   model is unavailable, or `Internal` for unexpected runtime failures.
    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let availability = await runtime.availability()
        guard availability == .available else {
            throw createCapabilityMismatch(
                message: "Apple Foundation Models provider is unavailable.",
                runId: context.runId,
                providerId: id,
                details: ["availability": JSONAny(availability.description)]
            )
        }

        do {
            let outputText = try await runtime.respond(
                to: normalizedPrompt(from: request),
                options: AppleFoundationModelsGenerationOptions(
                    maxOutputTokens: request.generation?.maxOutputTokens,
                    temperature: request.generation?.temperature
                )
            )

            return TaskResult(
                runId: context.runId,
                output: Output(text: outputText),
                finishReason: .stop,
                telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
            )
        } catch {
            throw normalizedFailure(error, runId: context.runId)
        }
    }

    /// Executes a normalized Mode-2 text-to-text request on the system model.
    ///
    /// Apple's partial responses are cumulative, so every content event is a
    /// ``ProviderStreamEvent/snapshot(text:)``; the engine normalizes those into
    /// `content_snapshot` events and tracks the latest one as the run's partial
    /// text. Nothing is diffed into deltas here, because a diff would claim a
    /// token boundary Apple never reported.
    ///
    /// Cancellation is wired the same way as the HTTP providers: the caller's
    /// token cancels the producing task, which tears the underlying
    /// `ResponseStream` down. The descriptor still declares `soft` cancellation
    /// because Apple does not document that in-flight generation stops — the
    /// engine's Event Gate is what guarantees nothing reaches the caller after
    /// the terminal outcome.
    ///
    /// - Parameters:
    ///   - request: Canonical IndeRun text-to-text request.
    ///   - context: Engine stream context carrying the run id, host services, and
    ///     the caller-driven cancellation token.
    /// - Returns: The provider-shaped event stream for this run.
    public func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request: request, context: context, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            context.cancellation.onCancel { task.cancel() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        request: TaskRequest,
        context: ProviderStreamContext,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        // Re-checked immediately before execution for the same reason `run` does
        // it: a stale route decision must surface as CapabilityMismatch rather
        // than as a native FoundationModels failure mid-stream.
        let availability = await runtime.availability()
        guard availability == .available else {
            throw createCapabilityMismatch(
                message: "Apple Foundation Models provider is unavailable.",
                runId: context.runId,
                providerId: id,
                details: ["availability": JSONAny(availability.description)]
            )
        }

        var latestSnapshot = ""
        do {
            let snapshots = runtime.streamResponse(
                to: normalizedPrompt(from: request),
                options: AppleFoundationModelsGenerationOptions(
                    maxOutputTokens: request.generation?.maxOutputTokens,
                    temperature: request.generation?.temperature
                )
            )
            for try await snapshot in snapshots {
                if context.cancellation.isCancelled { return }
                latestSnapshot = snapshot
                continuation.yield(.snapshot(text: snapshot))
            }
        } catch is CancellationError {
            // Cancelling the consuming task is how this provider stops the
            // runtime stream, so a CancellationError here is the mechanism
            // working, not a fault. The engine emits the cancelled terminal.
            return
        } catch {
            if context.cancellation.isCancelled { return }
            throw normalizedFailure(error, runId: context.runId)
        }

        if context.cancellation.isCancelled { return }

        // Apple's stream reports neither a finish reason nor token usage, so
        // `stop` matches what Mode 1 already reports rather than inventing a
        // richer terminal than the runtime supports.
        continuation.yield(.done(finalText: latestSnapshot, finishReason: .stop, usage: nil))
    }

    /// Maps a runtime failure onto the error taxonomy, preserving an exception a
    /// runtime already normalized. Shared by `run` and `stream` so a given
    /// failure classifies identically in both modes.
    private func normalizedFailure(_ error: Error, runId: String) -> IndeRunException {
        if let error = error as? IndeRunException {
            return toIndeRunException(error, fallbackRunId: runId, fallbackProviderId: id)
        }

        return createInternal(
            message: "Apple Foundation Models execution failed.",
            runId: runId,
            providerId: id,
            details: ["originalError": JSONAny(error.localizedDescription)]
        )
    }

    /// Converts canonical text input into the single prompt string expected by
    /// `LanguageModelSession.respond(to:)`.
    private func normalizedPrompt(from request: TaskRequest) -> String {
        if let messages = request.messages, !messages.isEmpty {
            return messages
                .map { "\($0.role.rawValue): \($0.content)" }
                .joined(separator: "\n")
        }

        return request.prompt ?? ""
    }
}

/// Factory for Apple-platform provider registration.
///
/// This keeps provider registration explicit while giving apps a single helper
/// for the default Apple on-device provider set.
public enum AppleProviderRegistryFactory {
    /// Creates a registry containing `AppleFoundationModelsProvider`.
    ///
    /// - Returns: A new provider registry configured for Apple on-device execution.
    /// - Throws: `IndeRunException` if provider registration fails.
    public static func makeDefaultRegistry() throws -> ProviderRegistry {
        let registry = ProviderRegistry()
        try registry.register(AppleFoundationModelsProvider())
        return registry
    }
}

/// Production runtime bridge to Apple's FoundationModels framework.
///
/// Compile-time and runtime availability guards keep the Swift package buildable
/// on hosts and deployment targets where FoundationModels is absent or unusable.
private struct SystemAppleFoundationModelsRuntime: AppleFoundationModelsRuntime {
    /// Maps Apple's native system-model availability into the provider's compact
    /// availability shape.
    func availability() async -> AppleFoundationModelsAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: "System language model unavailable: \(reason).")
            }
        }
        #endif

        return .unavailable(reason: "Apple Foundation Models requires iOS 26.0, macOS 26.0, or visionOS 26.0.")
    }

    /// Sends the prompt to `LanguageModelSession` and returns the generated text.
    ///
    /// - Parameters:
    ///   - prompt: The provider-normalized text prompt.
    ///   - options: Generation options mapped to `GenerationOptions`.
    /// - Returns: The generated text content.
    func respond(to prompt: String, options: AppleFoundationModelsGenerationOptions) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let generationOptions = GenerationOptions(
                temperature: options.temperature,
                maximumResponseTokens: options.maxOutputTokens
            )
            let session = LanguageModelSession(model: .default)
            let response = try await session.respond(to: prompt, options: generationOptions)
            return response.content
        }
        #endif

        throw createCapabilityMismatch(message: "Apple Foundation Models is not available on this OS.")
    }

    /// Relays `LanguageModelSession.streamResponse(to:)` as cumulative text.
    ///
    /// Apple's snapshots are already cumulative, so each one is forwarded
    /// verbatim. Terminating the returned stream cancels the producing task,
    /// which is how the adapter stops generation on cancellation.
    func streamResponse(
        to prompt: String,
        options: AppleFoundationModelsGenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                let task = Task {
                    do {
                        let generationOptions = GenerationOptions(
                            temperature: options.temperature,
                            maximumResponseTokens: options.maxOutputTokens
                        )
                        let session = LanguageModelSession(model: .default)
                        for try await partial in session.streamResponse(to: prompt, options: generationOptions) {
                            continuation.yield(partial.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif

            continuation.finish(throwing: createCapabilityMismatch(
                message: "Apple Foundation Models is not available on this OS."
            ))
        }
    }
}

private extension AppleFoundationModelsAvailability {
    var description: String {
        switch self {
        case .available:
            return "available"
        case .unavailable(let reason):
            return reason
        }
    }
}
