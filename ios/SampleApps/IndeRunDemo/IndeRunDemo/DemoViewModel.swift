import Combine
import Foundation
import SwiftUI
import IndeRunAppleProviders
import IndeRunContracts
import IndeRunCore
import IndeRunOnnxProviders
import IndeRunOpenAIProviders
import IndeRunSwift

@MainActor
final class DemoViewModel: ObservableObject {
    enum PrivacyPreference: String, CaseIterable, Identifiable {
        case localRequired
        case localPreferred
        case cloudAllowed
        case cloudRequired

        var id: String { rawValue }

        var constraints: TaskRequestConstraints {
            switch self {
            case .localRequired:
                return TaskRequestConstraints(cloud: nil, privacy: .localRequired, timeoutMs: nil)
            case .localPreferred:
                return TaskRequestConstraints(cloud: nil, privacy: .localPreferred, timeoutMs: nil)
            case .cloudAllowed:
                return TaskRequestConstraints(cloud: nil, privacy: .cloudAllowed, timeoutMs: nil)
            case .cloudRequired:
                return TaskRequestConstraints(cloud: nil, privacy: .cloudRequired, timeoutMs: nil)
            }
        }

        var title: String {
            switch self {
            case .localRequired:
                return "Local Only"
            case .localPreferred:
                return "Prefer Local"
            case .cloudAllowed:
                return "Cloud Allowed"
            case .cloudRequired:
                return "Cloud Only"
            }
        }
    }

    struct ProviderBadge: Identifiable {
        let id: String
        let label: String
        let available: Bool
        let reason: String?
    }

    enum CapabilitiesState {
        case loading
        case ready([ProviderBadge])
        case failed
    }

    struct RouteDecision {
        let selectedProviderId: String?
        let explanation: String
        let rejectedProviderIds: [String]
        let fallbackProviderIds: [String]
    }

    struct AttemptMetadata {
        let runId: String
        let providerUsed: String
        let totalMs: Double?
        let providerId: String?
        let retryAfterMs: Int?

        var totalMsDescription: String {
            guard let totalMs else { return "n/a" }
            return String(format: "%.0f", totalMs)
        }
    }

    struct ResultState {
        let outputText: String
        let metadata: AttemptMetadata
    }

    struct ErrorState {
        let title: String
        let body: String
        let metadata: AttemptMetadata?
    }

    private enum DefaultsKey {
        static let endpointURL = "inderun.demo.cloudEndpointURL"
        static let model = "inderun.demo.cloudModel"
        static let onnxModelSelection = "inderun.demo.onnxModelSelection"
    }

    private static let providerLabels: [String: String] = [
        "apple_foundation_models": "Apple On-Device",
        "openai_compatible_cloud": "Cloud",
        OnnxRuntimeAppleProvider.defaultId: "ONNX Local"
    ]

    static let defaultCloudEndpointURL = "http://127.0.0.1:8787/api/inderun/openai-responses"
    static let defaultCloudModel = "gpt-5.2"

    // A declarative sentence fragment, not an instruction: the default ONNX Local model
    // (DistilGPT-2, a non-instruction-tuned base model with no chat template) continues plain
    // text far more reliably than it follows a task instruction, which it often responds to by
    // immediately predicting the end-of-text token -- i.e. empty output.
    @Published var prompt = "On-device AI is useful because"
    @Published var privacy: PrivacyPreference = .cloudAllowed
    @Published var cloudEndpointURL: String {
        didSet { persistCloudSettings() }
    }
    @Published var cloudModel: String {
        didSet { persistCloudSettings() }
    }
    @Published var onnxModelSelection: DemoOnnxModelSelection {
        didSet {
            userDefaults.set(onnxModelSelection.rawValue, forKey: DefaultsKey.onnxModelSelection)
            Task { await ensureSelectedOnnxModelDownloaded() }
        }
    }
    @Published private(set) var onnxDownloadState: DemoOnnxDownloadState = .idle
    @Published private(set) var capabilitiesState: CapabilitiesState = .loading
    @Published private(set) var result: ResultState?
    @Published private(set) var errorState: ErrorState?
    @Published private(set) var lastRouteDecision: RouteDecision?
    @Published private(set) var isRunning = false
    /// Text assembled from Mode 2 content events as they arrive.
    @Published private(set) var streamedText = ""
    /// Human-readable terminal outcome of the last stream, or nil before one ran.
    @Published private(set) var streamOutcome: String?
    @Published private(set) var isStreaming = false

    private let hostServices: HostServices
    private let userDefaults: UserDefaults
    private let telemetryService = DemoTelemetryService()
    private let onDeviceProvider = AppleFoundationModelsProvider()
    /// Held only so `cancelStream` can reach the run's cancel hook; the stream is
    /// consumed by `streamPrompt`, which clears this when it terminates.
    private var streamRun: StreamRun?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.cloudEndpointURL = userDefaults.string(forKey: DefaultsKey.endpointURL) ?? Self.defaultCloudEndpointURL
        self.cloudModel = userDefaults.string(forKey: DefaultsKey.model) ?? Self.defaultCloudModel
        let persistedSelection = userDefaults.string(forKey: DefaultsKey.onnxModelSelection)
            .flatMap(DemoOnnxModelSelection.init(rawValue:))
        // Defaults to a real downloadable model (not the fixture) so the demo generates actual
        // text on first launch with no manual setup, mirroring the web demo's default experience.
        self.onnxModelSelection = persistedSelection ?? .distilgpt2Quantized
        self.hostServices = DefaultHostServices.make()
    }

    var cloudSettingsHint: String {
        "The default endpoint targets the local demo proxy on port 8787. On a physical device, replace 127.0.0.1 with your machine's LAN IP or another reachable proxy or server URL."
    }

    var onnxSettingsHint: String {
        switch onnxDownloadState {
        case .idle:
            return onnxModelSelection.modelOption == nil
                ? "The fixture runtime echoes the prompt back instead of generating text."
                : "Downloads automatically on first use and is cached afterward. Wi-Fi recommended."
        case .downloading(let progress):
            return "Downloading model... \(Int((progress * 100).rounded()))%. The fixture runtime is used until this completes."
        case .ready:
            return "Model downloaded and ready for on-device inference."
        case .failed(let message):
            return "Download failed: \(message). Falls back to the fixture runtime until this succeeds; pick the model again to retry."
        }
    }

    /// Kicks off (or resumes) the download for the selected model, if any and not already
    /// cached. Called on selection change and on app launch alongside `refreshAvailability()`.
    func ensureSelectedOnnxModelDownloaded() async {
        guard let model = onnxModelSelection.modelOption else {
            onnxDownloadState = .idle
            return
        }

        if DemoOnnxModelDownloader.shared.isDownloaded(model) {
            onnxDownloadState = .ready
            return
        }

        let progress = Progress(totalUnitCount: 1000)
        onnxDownloadState = .downloading(progress: 0)

        let pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.onnxDownloadState = .downloading(progress: progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        do {
            try await DemoOnnxModelDownloader.shared.download(model, into: progress)
            pollTask.cancel()
            onnxDownloadState = .ready
            await refreshAvailability()
        } catch {
            pollTask.cancel()
            onnxDownloadState = .failed(error.localizedDescription)
        }
    }

    var canRun: Bool {
        !isRunning && !isStreaming && !trimmedPrompt.isEmpty
    }

    func refreshAvailability() async {
        capabilitiesState = .loading

        do {
            let inderun = try makeIndeRun()
            let snapshots = await inderun.checkCapabilities()
            let usingRealOnnxModel = onnxModelSelection.modelOption.map { DemoOnnxModelDownloader.shared.isDownloaded($0) } ?? false
            let badges = snapshots.map { snapshot -> ProviderBadge in
                var label = Self.providerLabels[snapshot.providerId] ?? snapshot.descriptor.type.rawValue
                if snapshot.providerId == OnnxRuntimeAppleProvider.defaultId && !usingRealOnnxModel {
                    label += " (fixture)"
                }
                return ProviderBadge(
                    id: snapshot.providerId,
                    label: label,
                    available: snapshot.capabilities.available,
                    reason: snapshot.capabilities.reason
                )
            }
            capabilitiesState = .ready(badges)
        } catch {
            capabilitiesState = .failed
        }
    }

    func runPrompt() async {
        isRunning = true
        result = nil
        errorState = nil
        defer { isRunning = false }

        do {
            let inderun = try makeIndeRun()
            let request = TaskRequest(
                prompt: trimmedPrompt,
                // SystemOnnxGenAiRuntime recomputes the full sequence on every decode step (no
                // KV-cache reuse -- see docs/architecture/onnx-runtime-provider-family.md and
                // https://github.com/independo-gmbh/inderun/issues/126), so the default 256-token
                // budget is heavy enough to risk a memory-pressure kill on-device. Cap it low for
                // this demo; real apps needing longer output should wait for #126 or supply a
                // custom runtime.
                generation: Generation(maxOutputTokens: 32, seed: nil, stop: nil, temperature: nil, topP: nil),
                constraints: privacy.constraints
            )
            let taskResult = try await inderun.run(request: request)

            result = ResultState(
                outputText: taskResult.output.text,
                metadata: AttemptMetadata(
                    runId: taskResult.runId,
                    providerUsed: taskResult.telemetry.providerUsed,
                    totalMs: taskResult.telemetry.totalMs,
                    providerId: taskResult.telemetry.providerUsed,
                    retryAfterMs: nil
                )
            )
        } catch {
            present(error: error)
        }

        lastRouteDecision = telemetryService.lastRouteDecision()
        await refreshAvailability()
    }

    /// Runs the same request in Mode 2 and renders content events as they arrive.
    ///
    /// The only providers that stream today are Apple Foundation Models (on-device)
    /// and the OpenAI-compatible cloud provider, so `Local Only` streams solely on
    /// an Apple-Intelligence-capable device; elsewhere routing refuses the request
    /// with a normalized `CapabilityMismatch` before any event is produced.
    func streamPrompt() async {
        isStreaming = true
        streamedText = ""
        streamOutcome = nil
        result = nil
        errorState = nil
        defer {
            isStreaming = false
            streamRun = nil
        }

        do {
            let inderun = try makeIndeRun()
            let request = TaskRequest(
                prompt: trimmedPrompt,
                // Same low output budget as `runPrompt`, for the same ONNX memory-pressure
                // reason -- the request is provider-agnostic and may route anywhere.
                generation: Generation(maxOutputTokens: 32, seed: nil, stop: nil, temperature: nil, topP: nil),
                constraints: privacy.constraints
            )

            let run = try await inderun.stream(request: request)
            streamRun = run

            for try await event in run.events {
                switch event.type {
                case "content_delta":
                    streamedText += event.payload?.text ?? ""
                case "content_snapshot":
                    // Snapshots are cumulative (Apple Foundation Models), so they
                    // replace the accumulated text rather than appending to it.
                    streamedText = event.payload?.text ?? streamedText
                case "terminal":
                    applyTerminal(event, handle: run.handle)
                default:
                    break
                }
            }
        } catch {
            // Validation and routing failures reject `stream()` itself; everything
            // after that arrives as the terminal event handled above.
            present(error: error)
        }

        lastRouteDecision = telemetryService.lastRouteDecision()
        await refreshAvailability()
    }

    /// Requests cancellation of the in-flight stream. Idempotent, and the engine
    /// guarantees exactly one terminal outcome regardless of when it lands.
    func cancelStream() {
        streamRun?.cancel(reason: "cancelled from the demo app")
    }

    /// Maps the single terminal `StreamEvent` onto the same result/error panels the
    /// Mode 1 path uses, so both modes present outcomes identically.
    private func applyTerminal(_ event: StreamEvent, handle: StreamRunHandle) {
        guard let payload = event.payload else { return }

        switch payload.outcome {
        case .completed:
            streamOutcome = "completed"
            streamedText = payload.finalText ?? streamedText
            result = ResultState(
                outputText: payload.finalText ?? streamedText,
                metadata: AttemptMetadata(
                    runId: payload.runId ?? handle.runId,
                    providerUsed: payload.telemetry?.providerUsed ?? handle.providerId ?? "n/a",
                    totalMs: payload.telemetry?.totalMs,
                    providerId: payload.telemetry?.providerUsed ?? handle.providerId,
                    retryAfterMs: nil
                )
            )
        case .cancelled:
            // Not an error: a cancelled run is a normal terminal outcome carrying
            // whatever content was delivered before the cancel landed.
            streamOutcome = payload.reason.map { "cancelled: \($0)" } ?? "cancelled"
            streamedText = payload.partialText ?? streamedText
        case .error:
            streamOutcome = "error"
            streamedText = payload.partialText ?? streamedText
            errorState = ErrorState(
                title: "Normalized Error",
                body: """
\(payload.error?.errorClass.rawValue ?? "Internal")

\(payload.error?.message ?? "The stream failed without a message.")
""",
                metadata: AttemptMetadata(
                    runId: payload.runId ?? handle.runId,
                    providerUsed: payload.error?.providerId ?? handle.providerId ?? "n/a",
                    totalMs: payload.telemetry?.totalMs,
                    providerId: payload.error?.providerId,
                    retryAfterMs: payload.error?.retryAfterMs
                )
            )
        case .none:
            break
        }
    }

    /// Shared error presentation for both modes.
    private func present(error: Error) {
        guard let error = error as? IndeRunException else {
            errorState = ErrorState(
                title: "Unexpected Error",
                body: error.localizedDescription,
                metadata: nil
            )
            return
        }

        // `details.originalError` (when present) carries the underlying native error message
        // an adapter attached before normalizing to this generic `IndeRunException` -- surface
        // it here rather than silently dropping it, since it's often the only clue to what
        // actually failed (e.g. the raw ONNX Runtime error text behind an "Internal" class).
        let originalErrorSuffix = error.details?["originalError"]?.stringValue.map { "\n\nOriginal error:\n\($0)" } ?? ""
        errorState = ErrorState(
            title: "Normalized Error",
            body: """
\(error.errorClass.rawValue)

\(error.message)\(originalErrorSuffix)
""",
            metadata: AttemptMetadata(
                runId: error.runId ?? "n/a",
                providerUsed: error.providerId ?? "n/a",
                totalMs: error.details?["totalMs"]?.doubleValue,
                providerId: error.providerId,
                retryAfterMs: error.retryAfterMs
            )
        )
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCloudEndpointURL: String {
        cloudEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCloudModel: String {
        cloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistCloudSettings() {
        userDefaults.set(trimmedCloudEndpointURL, forKey: DefaultsKey.endpointURL)
        userDefaults.set(trimmedCloudModel, forKey: DefaultsKey.model)
    }

    private func makeIndeRun() throws -> IndeRun {
        let registry = ProviderRegistry()
        try registry.register(onDeviceProvider)
        try registry.register(makeOnnxProvider())
        try registry.register(makeCloudProvider())
        return IndeRun(registry: registry, hostServices: hostServices, telemetryService: telemetryService)
    }

    private func makeOnnxProvider() -> OnnxRuntimeAppleProvider {
        if let model = onnxModelSelection.modelOption, DemoOnnxModelDownloader.shared.isDownloaded(model) {
            let directory = DemoOnnxModelDownloader.shared.localDirectory(for: model)
            let modelPackage = ModelPackage(
                files: Files(
                    config: nil,
                    external: nil,
                    filesRequired: ["model.onnx"],
                    tokenizer: "tokenizer.json"
                ),
                format: .onnx,
                id: model.id,
                integrity: nil,
                license: nil,
                limits: nil,
                runtime: nil,
                source: Source(ref: directory.path, sourceType: .filesystem),
                tasks: ["text_to_text"],
                version: nil
            )
            // No runtime override: defaults to SystemOnnxGenAiRuntime(), real ONNX Runtime inference.
            return OnnxRuntimeAppleProvider(options: OnnxProviderOptions(modelPackage: modelPackage))
        }

        // Fixture (either selected explicitly, or the real model hasn't finished downloading
        // yet) -- it echoes the prompt, it does not generate text -- so the demo still works
        // out of the box while a real model downloads in the background.
        let modelPackage = ModelPackage(
            files: nil,
            format: .onnx,
            id: "demo-fixture-model",
            integrity: nil,
            license: nil,
            limits: nil,
            runtime: nil,
            source: Source(ref: nil, sourceType: .programmatic),
            tasks: ["text_to_text"],
            version: nil
        )
        return OnnxRuntimeAppleProvider(
            options: OnnxProviderOptions(
                modelPackage: modelPackage,
                runtime: createFixtureOnnxRuntime()
            )
        )
    }

    private func makeCloudProvider() -> OpenAIProvider {
        OpenAIProvider(
            options: OpenAIProviderOptions(
                id: "openai_compatible_cloud",
                model: trimmedCloudModel,
                endpointURL: trimmedCloudEndpointURL,
                auth: .none
            )
        )
    }
}

/// Captures the last `route_decided` telemetry event so the UI can show a routing
/// transparency panel, mirroring the web demo's `RouteDecisionTelemetryService`.
final class DemoTelemetryService: TelemetryService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var lastEvent: TelemetryEvent?

    func emit(event: TelemetryEvent) {
        guard event.type == .routeDecided else { return }
        lock.lock()
        lastEvent = event
        lock.unlock()
    }

    func lastRouteDecision() -> DemoViewModel.RouteDecision? {
        lock.lock()
        let event = lastEvent
        lock.unlock()

        guard let event else { return nil }

        return DemoViewModel.RouteDecision(
            selectedProviderId: event.payload["selectedProviderId"]?.stringValue,
            explanation: event.payload["explanation"]?.stringValue ?? "",
            rejectedProviderIds: event.payload["rejectedProviderIds"]?.stringArrayValue ?? [],
            fallbackProviderIds: event.payload["fallbackProviderIds"]?.stringArrayValue ?? []
        )
    }
}

private extension JSONAny {
    var doubleValue: Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int64 {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    var stringValue: String? {
        value as? String
    }

    var stringArrayValue: [String]? {
        value as? [String]
    }
}
