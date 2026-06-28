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
    /// The system language model is available for immediate Mode-1 execution.
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
}

/// On-device Mode-1 text-to-text provider backed by Apple Foundation Models.
///
/// The provider is deliberately not auto-registered. Apps opt in by registering
/// this adapter directly or by using `AppleProviderRegistryFactory`. Runtime
/// availability still depends on OS support, device eligibility, Apple
/// Intelligence enablement, and model readiness.
public final class AppleFoundationModelsProvider: ProviderAdapter, Sendable {
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
            tasks: ["text_to_text"],
            privacy: ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice: false)
        )
    }

    /// Reports whether Apple's system language model is usable right now.
    ///
    /// Host services are accepted to satisfy the provider contract; this provider
    /// currently relies only on Apple's system model availability.
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
        } catch let error as IndeRunException {
            throw toIndeRunException(error, fallbackRunId: context.runId, fallbackProviderId: id)
        } catch {
            throw createInternal(
                message: "Apple Foundation Models execution failed.",
                runId: context.runId,
                providerId: id,
                details: ["originalError": JSONAny(error.localizedDescription)]
            )
        }
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
