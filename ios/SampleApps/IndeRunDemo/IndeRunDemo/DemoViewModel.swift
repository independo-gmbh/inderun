import Combine
import Foundation
import SwiftUI
import IndeRunAppleProviders
import IndeRunContracts
import IndeRunCore
import IndeRunOpenAIProviders
import IndeRunSwift

@MainActor
final class DemoViewModel: ObservableObject {
    enum ExecutionMode: String, CaseIterable, Identifiable {
        case onDevice
        case cloud

        var id: String { rawValue }

        var requestConstraints: TaskRequestConstraints {
            switch self {
            case .onDevice:
                return TaskRequestConstraints(privacy: .localRequired)
            case .cloud:
                return TaskRequestConstraints(privacy: .cloudRequired)
            }
        }

        var title: String {
            switch self {
            case .onDevice:
                return "On Device"
            case .cloud:
                return "Cloud"
            }
        }
    }

    enum AvailabilityState {
        case checking(String)
        case available(String)
        case unavailable(String)

        var title: String {
            switch self {
            case .checking:
                return "Checking"
            case .available:
                return "Available"
            case .unavailable:
                return "Unavailable"
            }
        }

        var message: String {
            switch self {
            case .checking(let message), .available(let message), .unavailable(let message):
                return message
            }
        }

        var color: Color {
            switch self {
            case .checking:
                return .secondary
            case .available:
                return .green
            case .unavailable:
                return .red
            }
        }
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
    }

    private enum CloudEndpointReachability {
        case reachable(statusCode: Int)
        case unreachable(message: String)
    }

    private static let demoProxyPath = "/api/inderun/openai-responses"
    static let defaultCloudEndpointURL = "http://127.0.0.1:8787/api/inderun/openai-responses"
    static let defaultCloudModel = "gpt-5.2"

    @Published var prompt = "Summarize when on-device AI is preferable to cloud AI in two short sentences."
    @Published var executionMode: ExecutionMode = .onDevice
    @Published var cloudEndpointURL: String {
        didSet { persistCloudSettings() }
    }
    @Published var cloudModel: String {
        didSet { persistCloudSettings() }
    }
    @Published private(set) var onDeviceStatus: AvailabilityState = .checking("Checking whether Apple Foundation Models are usable right now.")
    @Published private(set) var cloudStatus: AvailabilityState = .checking("Checking local cloud configuration and network state.")
    @Published private(set) var result: ResultState?
    @Published private(set) var errorState: ErrorState?
    @Published private(set) var isRunning = false

    private let hostServices: HostServices
    private let userDefaults: UserDefaults
    private let onDeviceProvider = AppleFoundationModelsProvider()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.cloudEndpointURL = userDefaults.string(forKey: DefaultsKey.endpointURL) ?? Self.defaultCloudEndpointURL
        self.cloudModel = userDefaults.string(forKey: DefaultsKey.model) ?? Self.defaultCloudModel
        self.hostServices = DefaultHostServices.make()
    }

    var executionModeDescription: String {
        switch executionMode {
        case .onDevice:
            return "Use Apple Foundation Models directly through the IndeRun Apple provider. This requires a supported physical device and current Apple Intelligence availability."
        case .cloud:
            return "Use the IndeRun OpenAI-compatible provider against the configured endpoint. For local simulator testing, point this at the standalone demo proxy."
        }
    }

    var cloudSettingsHint: String {
        "The default endpoint targets the local demo proxy on port 8787. On a physical device, replace 127.0.0.1 with your machine's LAN IP or another reachable proxy or server URL."
    }

    var runButtonTitle: String {
        switch executionMode {
        case .onDevice:
            return "Run On Device"
        case .cloud:
            return "Run Through Cloud"
        }
    }

    var canRun: Bool {
        guard !isRunning else { return false }
        guard !trimmedPrompt.isEmpty else { return false }

        switch executionMode {
        case .onDevice:
            return true
        case .cloud:
            return !trimmedCloudEndpointURL.isEmpty &&
                !trimmedCloudModel.isEmpty &&
                URL(string: trimmedCloudEndpointURL) != nil
        }
    }

    func refreshAvailability() async {
        let onDeviceCapabilities = await onDeviceProvider.capabilities(host: hostServices)
        if onDeviceCapabilities.available {
            onDeviceStatus = .available("Apple Foundation Models reported availability for this device and current system state.")
        } else {
            onDeviceStatus = .unavailable("Apple Foundation Models are not currently available. Device eligibility, Apple Intelligence enablement, locale, or model readiness may be blocking execution.")
        }

        guard !trimmedCloudEndpointURL.isEmpty else {
            cloudStatus = .unavailable("Enter a cloud endpoint URL. The default local proxy URL is http://127.0.0.1:8787/api/inderun/openai-responses.")
            return
        }

        guard URL(string: trimmedCloudEndpointURL) != nil else {
            cloudStatus = .unavailable("The configured cloud endpoint URL is not valid.")
            return
        }

        guard !trimmedCloudModel.isEmpty else {
            cloudStatus = .unavailable("Enter a model name for the cloud request.")
            return
        }

        let online = await hostServices.connectivity.isOnline()
        let cloudCapabilities = await makeCloudProvider().capabilities(host: hostServices)

        guard cloudCapabilities.available else {
            cloudStatus = .unavailable("The host is missing the HTTP support required for cloud execution.")
            return
        }

        if !online {
            cloudStatus = .unavailable("Device is offline. The cloud route will fail before the endpoint is contacted.")
            return
        }

        switch await probeCloudEndpoint() {
        case .reachable(let statusCode):
            cloudStatus = .available("Cloud execution is configured and the endpoint is reachable. Probe status: \(statusCode). Requests will use app-side auth disabled.")
        case .unreachable(let message):
            cloudStatus = .unavailable(message)
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
                constraints: executionMode.requestConstraints
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

            switch executionMode {
            case .onDevice:
                onDeviceStatus = .available("The last on-device request completed successfully.")
            case .cloud:
                cloudStatus = .available("The configured cloud route completed the last request successfully.")
            }
        } catch let error as IndeRunException {
            if error.errorClass == .CapabilityMismatch {
                onDeviceStatus = .unavailable("The provider rejected on-device execution for the current device or system state.")
            }

            if error.errorClass == .Offline {
                cloudStatus = .unavailable("Device is offline. Reconnect or switch to on-device mode.")
            }

            if executionMode == .cloud && error.errorClass == .Unavailable {
                cloudStatus = .unavailable(unavailableCloudMessage())
            }

            errorState = ErrorState(
                title: "Normalized Error",
                body: """
\(error.errorClass.rawValue)

\(error.message)
""",
                metadata: AttemptMetadata(
                    runId: error.runId ?? "n/a",
                    providerUsed: error.providerId ?? executionMode.rawValue,
                    totalMs: error.details?["totalMs"]?.doubleValue,
                    providerId: error.providerId,
                    retryAfterMs: error.retryAfterMs
                )
            )
        } catch {
            errorState = ErrorState(
                title: "Unexpected Error",
                body: error.localizedDescription,
                metadata: nil
            )
        }
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
        try registry.register(makeCloudProvider())
        return IndeRun(registry: registry, hostServices: hostServices)
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

    private func probeCloudEndpoint() async -> CloudEndpointReachability {
        guard let httpClient = hostServices.httpClient else {
            return .unreachable(message: "The host is missing the HTTP support required for cloud execution.")
        }

        let probeURL = cloudProbeURL()
        let request = HttpRequest(
            method: .get,
            url: probeURL,
            timeoutMs: 2_000
        )

        do {
            let response = try await httpClient.send(request: request)
            return .reachable(statusCode: response.status)
        } catch {
            return .unreachable(message: unavailableCloudMessage())
        }
    }

    private func cloudProbeURL() -> String {
        guard let url = URL(string: trimmedCloudEndpointURL) else {
            return trimmedCloudEndpointURL
        }

        if url.path == Self.demoProxyPath, let healthURL = buildHealthURL(from: url) {
            return healthURL.absoluteString
        }

        return trimmedCloudEndpointURL
    }

    private func buildHealthURL(from endpointURL: URL) -> URL? {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func unavailableCloudMessage() -> String {
        if let url = URL(string: trimmedCloudEndpointURL),
           let host = url.host,
           (host == "127.0.0.1" || host == "localhost"),
           url.port == 8787,
           url.path == Self.demoProxyPath {
            return "Could not reach the local demo proxy at \(trimmedCloudEndpointURL). Start `pnpm --filter @independo/inderun-demo-proxy dev` or change the endpoint URL."
        }

        return "Could not reach the configured cloud endpoint at \(trimmedCloudEndpointURL). Check the URL, port, server process, and network path."
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
}
