#if canImport(Capacitor)
import Capacitor
#else
typealias JSObject = [String: Any]
#endif
import Foundation
import IndeRunAppleProviders
import IndeRunCore
import IndeRunContracts
import IndeRunOpenAIProviders
import IndeRunSwift

struct OpenAIProviderBootstrapOptions: Codable {
    let model: String
    let endpointURL: String?
    let auth: String?
    let authContextRef: String?
    let timeoutMs: Int?
}

struct CapacitorRunOptions: Codable {
    let openAI: OpenAIProviderBootstrapOptions?
    let allowDirectOpenAIEndpoint: Bool? // web-only, no-op on native
}

final class IndeRunCapacitorBridge {
    private var configuredRegistry: ProviderRegistry?
    private var configuredHostServices: HostServices?

    func configure(options: JSObject) throws {
        let runOptions = try decodeConfigureOptions(from: options)
        configuredRegistry = try makeRegistry(openAI: runOptions.openAI)
        configuredHostServices = DefaultHostServices.make()
    }

    func run(requestObject: JSObject) async throws -> JSObject {
        guard let registry = configuredRegistry, let hostServices = configuredHostServices else {
            throw createUnavailable(message: "Capacitor IndeRun has not been configured. Configure providers before calling run(request).")
        }

        let request = try decodeRequest(from: requestObject)
        // IndeRun is a stateless coordinator; new per call is intentional — registry is cached above.
        let engine = IndeRun(registry: registry, hostServices: hostServices)
        let result = try await engine.run(request: request)
        return try encode(result)
    }

    func encode(error: IndeRunError) throws -> JSObject {
        try encodeObject(error)
    }

    private func makeRegistry(openAI: OpenAIProviderBootstrapOptions?) throws -> ProviderRegistry {
        let registry = ProviderRegistry()
        try registry.register(AppleFoundationModelsProvider())

        if let openAI {
            try registry.register(
                OpenAIProvider(
                    options: OpenAIProviderOptions(
                        id: "openai",
                        model: openAI.model,
                        endpointURL: openAI.endpointURL ?? defaultOpenAIResponsesEndpoint,
                        auth: mapAuthMode(openAI.auth),
                        authContextRef: openAI.authContextRef,
                        timeoutMs: openAI.timeoutMs
                    )
                )
            )
        }

        return registry
    }

    private func decodeConfigureOptions(from object: JSObject) throws -> CapacitorRunOptions {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try JSONDecoder().decode(CapacitorRunOptions.self, from: data)
    }

    private func decodeRequest(from object: JSObject) throws -> TaskRequest {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try JSONDecoder().decode(TaskRequest.self, from: data)
    }

    private func encode(_ result: TaskResult) throws -> JSObject {
        try encodeObject(result)
    }

    private func encodeObject<T: Encodable>(_ value: T) throws -> JSObject {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? JSObject else {
            throw createInternal(message: "Capacitor bridge failed to encode a JSON object.")
        }
        return dictionary
    }

    func mapAuthMode(_ value: String?) -> OpenAIAuthMode {
        switch value {
        case "none":
            return .none
        default:
            return .authContextRef
        }
    }
}
