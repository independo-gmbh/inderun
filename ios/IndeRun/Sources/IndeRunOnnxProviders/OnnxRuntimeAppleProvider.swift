import Foundation
import IndeRunContracts
import IndeRunCore

/// Task kind this provider implements in Milestone 2 (Mode 1 only).
private let textToText = "text_to_text"

/// Configuration for the Apple ONNX Runtime provider.
public struct OnnxProviderOptions: Sendable {
    /// Provider id exposed in telemetry and routing explanations.
    public var id: String
    /// Provider-neutral bootstrap metadata describing the developer-supplied model.
    public var modelPackage: ModelPackage
    /// Runtime implementation used to execute generation. Defaults to the ONNX Runtime SPM +
    /// swift-transformers-backed runtime; applications can inject their own implementation of
    /// the seam.
    public var runtime: (any OnnxGenAiRuntime)?
    /// Optional generation timeout. A request-level `constraints.timeoutMs` wins.
    public var timeout: Duration?

    public init(
        id: String = OnnxRuntimeAppleProvider.defaultId,
        modelPackage: ModelPackage,
        runtime: (any OnnxGenAiRuntime)? = nil,
        timeout: Duration? = nil
    ) {
        self.id = id
        self.modelPackage = modelPackage
        self.runtime = runtime
        self.timeout = timeout
    }
}

/// Local provider adapter that executes Mode-1 text-to-text requests with a developer-supplied
/// ONNX model on Apple platforms.
///
/// The adapter owns the IndeRun-facing contract (descriptor, capability checks, error taxonomy)
/// and delegates execution to an injectable `OnnxGenAiRuntime`. ONNX Runtime execution backends
/// (CPU, CoreML, XNNPACK) stay behind that seam and are never public routing concepts.
public final class OnnxRuntimeAppleProvider: ProviderAdapter, Sendable {
    /// Default provider id of the Apple-platform member of the ONNX Runtime provider family.
    public static let defaultId = "local.onnx.genai.apple"

    /// Model source types the Apple member of the ONNX Runtime provider family can honor, per the
    /// support matrix in `docs/architecture/onnx-runtime-provider-family.md`: `registry` and
    /// `remote` are deferred everywhere at this stage; Apple additionally supports `filesystem`
    /// (unlike Web, which cannot read arbitrary local paths).
    public static let supportedModelSourceTypes: [SourceType] = [.bundled, .programmatic, .appManaged, .filesystem]

    private let id: String
    private let modelPackage: ModelPackage
    private let runtime: any OnnxGenAiRuntime
    private let timeout: Duration?

    /// Creates an Apple ONNX Runtime provider.
    /// - Parameter options: Model package plus optional id, runtime, and timeout overrides.
    public init(options: OnnxProviderOptions) {
        self.id = options.id
        self.modelPackage = options.modelPackage
        self.runtime = options.runtime ?? SystemOnnxGenAiRuntime()
        self.timeout = options.timeout
    }

    /// Returns static metadata used by the router for deterministic provider selection.
    public func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
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
            tasks: declaredTasks(modelPackage),
            privacy: ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice: false)
        )
    }

    /// Reports dynamic provider availability for the current host.
    ///
    /// Every failure below is provider-internal detail: the shared route planner flattens it
    /// into a single `capability_unavailable` rejection carrying the returned reason.
    ///
    /// - Parameter host: Host services available to the engine (unused; ONNX runs in-process).
    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        let issues = getModelPackageValidationIssues(modelPackage)
        if !issues.isEmpty {
            let summary = issues.map { "\($0.path) \($0.message)" }.joined(separator: "; ")
            return ProviderDynamicCapabilities(available: false, reason: "model package malformed: \(summary)")
        }

        if let sourceType = modelPackage.source?.sourceType, !Self.supportedModelSourceTypes.contains(sourceType) {
            let supported = Self.supportedModelSourceTypes.map(\.rawValue).joined(separator: ", ")
            let rawValue = sourceType.rawValue
            let reason = sourceType == .registry || sourceType == .remote
                ? "model source unavailable: '\(rawValue)' model sources are deferred on Apple platforms; "
                    + "supply model files as \(supported)."
                : "model source unavailable: '\(rawValue)' model sources are unsupported on Apple platforms."
            return ProviderDynamicCapabilities(available: false, reason: reason)
        }

        if let platforms = modelPackage.runtime?.platforms, !platforms.isEmpty, !platforms.contains("apple") {
            return ProviderDynamicCapabilities(
                available: false,
                reason: "platform unsupported: the model package targets \(platforms.joined(separator: ", ")) and does not list 'apple'."
            )
        }

        let tasks = declaredTasks(modelPackage)
        if !tasks.contains(textToText) {
            let declared = tasks.joined(separator: ", ")
            return ProviderDynamicCapabilities(
                available: false,
                reason: "unsupported task: the model package declares \(declared) and does not support '\(textToText)'."
            )
        }

        let availability = await runtime.prepare(modelPackage)
        return ProviderDynamicCapabilities(available: availability.available, reason: availability.reason)
    }

    /// Executes a normalized text-to-text task on the developer-supplied local ONNX model.
    /// - Parameters:
    ///   - request: Canonical IndeRun task request.
    ///   - context: Engine execution context containing the run id and host services.
    /// - Returns: A normalized IndeRun task result.
    /// - Throws: `IndeRunException` mapped to the standard error taxonomy.
    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let availability = await capabilities(host: context.hostServices)
        guard availability.available else {
            throw createCapabilityMismatch(
                message: availability.reason ?? "ONNX Runtime Apple provider is unavailable on this host.",
                runId: context.runId,
                providerId: id
            )
        }

        let messages = createMessages(from: request)
        guard !messages.isEmpty else {
            throw createInternal(
                message: "ONNX Runtime Apple provider requires a prompt or messages.",
                runId: context.runId,
                providerId: id
            )
        }

        let effectiveTimeout = requestTimeout(from: request) ?? timeout
        let output: OnnxGenerationOutput
        do {
            output = try await runWithTimeout(effectiveTimeout) {
                try await self.runtime.generate(
                    OnnxGenerationInput(modelPackage: self.modelPackage, messages: messages, generation: request.generation)
                )
            }
        } catch is CancellationError {
            // Real Task cancellation propagates raw, uncaught, matching OpenAIProvider and
            // IndeRun.swift -- it is not normalized into an IndeRunException. Only the explicit
            // deadline branch in `runWithTimeout` below produces a `Timeout` IndeRunException.
            throw CancellationError()
        } catch {
            throw mapRuntimeError(error, context: context)
        }

        guard !output.text.isEmpty else {
            throw createInternal(
                message: "ONNX Runtime Apple provider returned no text output.",
                runId: context.runId,
                providerId: id
            )
        }

        return TaskResult(
            runId: context.runId,
            output: Output(text: output.text),
            finishReason: output.finishReason ?? .stop,
            usage: output.usage,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    private func mapRuntimeError(_ error: Error, context: RunContext) -> IndeRunException {
        if let runtimeError = error as? OnnxRuntimeError {
            var details: [String: JSONAny] = [:]
            if let original = runtimeError.originalErrorDescription {
                details["originalError"] = JSONAny(original)
            }
            let detailsArg = details.isEmpty ? nil : details

            switch runtimeError.kind {
            case .capability:
                return createCapabilityMismatch(message: runtimeError.message, runId: context.runId, providerId: id, details: detailsArg)
            case .unavailable:
                return createUnavailable(message: runtimeError.message, runId: context.runId, providerId: id, details: detailsArg)
            case .timeout:
                return createTimeout(message: runtimeError.message, runId: context.runId, providerId: id, details: detailsArg)
            case .internalFailure:
                return createInternal(message: runtimeError.message, runId: context.runId, providerId: id, details: detailsArg)
            }
        }

        if let indeRunError = error as? IndeRunException {
            return toIndeRunException(indeRunError, fallbackRunId: context.runId, fallbackProviderId: id)
        }

        return createInternal(
            message: "ONNX Runtime Apple provider execution failed.",
            runId: context.runId,
            providerId: id,
            details: ["originalError": JSONAny(String(describing: error))]
        )
    }
}

private func declaredTasks(_ modelPackage: ModelPackage) -> [String] {
    guard let tasks = modelPackage.tasks, !tasks.isEmpty else { return [textToText] }
    return tasks
}

private func createMessages(from request: TaskRequest) -> [OnnxGenerationMessage] {
    if let messages = request.messages, !messages.isEmpty {
        return messages.map { OnnxGenerationMessage(role: $0.role, content: $0.content) }
    }

    guard let prompt = request.prompt, !prompt.isEmpty else { return [] }
    return [OnnxGenerationMessage(role: .user, content: prompt)]
}

private func requestTimeout(from request: TaskRequest) -> Duration? {
    guard let timeoutMs = request.constraints?.timeoutMs, timeoutMs > 0 else { return nil }
    return .milliseconds(timeoutMs)
}

private func runWithTimeout<T: Sendable>(_ timeout: Duration?, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard let timeout else { return try await operation() }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw OnnxRuntimeError(kind: .timeout, message: "ONNX Runtime Apple generation timed out.")
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
