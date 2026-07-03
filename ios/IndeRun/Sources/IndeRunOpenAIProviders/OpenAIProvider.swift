import Foundation
import IndeRunContracts
import IndeRunCore

public let defaultOpenAIResponsesEndpoint = "https://api.openai.com/v1/responses"

public enum OpenAIAuthMode: String, Sendable {
    case authContextRef
    case none
}

public struct OpenAIProviderOptions: Sendable {
    public let id: String
    public let model: String
    public let endpointURL: String
    public let auth: OpenAIAuthMode
    public let authContextRef: String?
    public let timeoutMs: Int?

    public init(
        id: String = "openai",
        model: String,
        endpointURL: String = defaultOpenAIResponsesEndpoint,
        auth: OpenAIAuthMode = .authContextRef,
        authContextRef: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.id = id
        self.model = model
        self.endpointURL = endpointURL
        self.auth = auth
        self.authContextRef = authContextRef
        self.timeoutMs = timeoutMs
    }
}

private struct OpenAIResponseBody {
    let outputText: String?
    let output: [[String: Any]]
    let status: String?
    let incompleteReason: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    init(json: [String: Any]) {
        outputText = json["output_text"] as? String
        output = json["output"] as? [[String: Any]] ?? []
        status = json["status"] as? String
        let incompleteDetails = json["incomplete_details"] as? [String: Any]
        incompleteReason = incompleteDetails?["reason"] as? String
        let usage = json["usage"] as? [String: Any]
        inputTokens = usage?["input_tokens"] as? Int
        outputTokens = usage?["output_tokens"] as? Int
        totalTokens = usage?["total_tokens"] as? Int
    }
}

private struct OpenAIErrorBody {
    let message: String?
    let type: String?
    let code: String?

    init(json: [String: Any]) {
        let error = json["error"] as? [String: Any]
        message = error?["message"] as? String
        type = error?["type"] as? String
        code = error?["code"] as? String
    }
}

public final class OpenAIProvider: ProviderAdapter, Sendable {
    private let options: OpenAIProviderOptions

    public init(options: OpenAIProviderOptions) {
        self.options = options
    }

    public func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: options.id,
            type: .cloud,
            transport: .http,
            supports: ProviderDescriptor.SupportsCapabilities(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .hard,
            tasks: ["text_to_text"],
            privacy: ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice: true)
        )
    }

    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        guard host.httpClient != nil else {
            return ProviderDynamicCapabilities(
                available: false,
                reason: "OpenAI Responses provider requires an HttpClientService."
            )
        }

        if options.auth != .none && host.secureStorage == nil {
            return ProviderDynamicCapabilities(
                available: false,
                reason: "OpenAI Responses provider requires a SecureStorageService when auth is enabled."
            )
        }

        return ProviderDynamicCapabilities(available: true)
    }

    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        guard let httpClient = context.hostServices.httpClient else {
            throw createUnavailable(
                message: "OpenAI Responses provider requires an HTTP client.",
                runId: context.runId,
                providerId: options.id
            )
        }

        var headers = ["Content-Type": "application/json"]

        if options.auth == .authContextRef {
            let slotId = request.authContextRef ?? options.authContextRef
            guard let slotId, !slotId.isEmpty else {
                throw createAuthError(
                    message: "OpenAI Responses provider requires authContextRef.",
                    runId: context.runId,
                    providerId: options.id
                )
            }

            guard let secureStorage = context.hostServices.secureStorage else {
                throw createAuthError(
                    message: "OpenAI Responses provider requires a SecureStorageService when auth is enabled.",
                    runId: context.runId,
                    providerId: options.id
                )
            }

            guard let secret = await secureStorage.getSecret(slotId: slotId), !secret.isEmpty else {
                throw createAuthError(
                    message: "No OpenAI credential found for authContextRef '\(slotId)'.",
                    runId: context.runId,
                    providerId: options.id
                )
            }

            headers["Authorization"] = "Bearer \(secret)"
        }

        let body = try serializeJSONObject(createRequestBody(request: request))
        let httpRequest = HttpRequest(
            body: body,
            headers: headers,
            method: .post,
            timeoutMs: options.timeoutMs,
            url: options.endpointURL
        )

        let response: HttpResponse
        do {
            response = try await httpClient.send(request: httpRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw createUnavailable(
                message: "OpenAI Responses request failed before a response was received.",
                runId: context.runId,
                providerId: options.id,
                details: ["originalError": JSONAny(error.localizedDescription)]
            )
        }

        let status = response.status
        if status < 200 || status >= 300 {
            throw mapHTTPError(
                status: status,
                statusText: response.statusText,
                headers: response.headers,
                body: response.body,
                runId: context.runId
            )
        }

        let responseBody = OpenAIResponseBody(json: parseJSONObject(response.body))
        guard let outputText = extractOutputText(responseBody: responseBody) else {
            throw createInternal(
                message: "OpenAI Responses payload did not contain text output.",
                runId: context.runId,
                providerId: options.id
            )
        }

        var result = TaskResult(
            finishReason: finishReason(responseBody: responseBody),
            output: Output(text: outputText, type: .text),
            runId: context.runId,
            schemaVersion: .the10,
            telemetry: TaskResultTelemetry(errorClass: nil, providerUsed: options.id, totalMs: 0),
            usage: nil
        )

        if let usage = usage(responseBody: responseBody) {
            result.usage = usage
        }

        return result
    }

    private func createRequestBody(request: TaskRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "input": createInput(request: request)
        ]

        if let generation = request.generation {
            if let maxOutputTokens = generation.maxOutputTokens {
                body["max_output_tokens"] = maxOutputTokens
            }
            if let temperature = generation.temperature {
                body["temperature"] = temperature
            }
            if let topP = generation.topP {
                body["top_p"] = topP
            }
            if let stop = generation.stop {
                body["stop"] = stop
            }
        }

        return body
    }

    private func mapHTTPError(
        status: Int,
        statusText: String,
        headers: [String: String],
        body: String,
        runId: String
    ) -> IndeRunException {
        let errorBody = OpenAIErrorBody(json: parseJSONObject(body))
        let message = errorBody.message ?? "OpenAI Responses request failed with HTTP \(status) \(statusText)."
        var details: [String: JSONAny] = [
            "status": JSONAny(status),
            "statusText": JSONAny(statusText)
        ]
        if let type = errorBody.type {
            details["errorType"] = JSONAny(type)
        }
        if let code = errorBody.code {
            details["errorCode"] = JSONAny(code)
        }

        if status == 401 || status == 403 {
            return createAuthError(message: message, runId: runId, providerId: options.id, details: details)
        }

        if status == 429 {
            let retryAfterMs = parseRetryAfterMs(headers: headers)
            return createRateLimited(
                message: message,
                runId: runId,
                providerId: options.id,
                retryable: true,
                retryAfterMs: retryAfterMs,
                details: details
            )
        }

        if status == 408 || status == 504 {
            return createTimeout(
                message: message,
                runId: runId,
                providerId: options.id,
                retryable: true,
                details: details
            )
        }

        if status == 409 || status >= 500 {
            return createUnavailable(
                message: message,
                runId: runId,
                providerId: options.id,
                retryable: true,
                details: details
            )
        }

        return createInternal(message: message, runId: runId, providerId: options.id, details: details)
    }

    private func createInput(request: TaskRequest) -> Any {
        if let messages = request.messages, !messages.isEmpty {
            return messages.map { message in
                [
                    "role": message.role == .system ? "developer" : message.role.rawValue,
                    "content": message.content
                ]
            }
        }

        return request.prompt ?? ""
    }

    private func extractOutputText(responseBody: OpenAIResponseBody) -> String? {
        if let outputText = responseBody.outputText {
            return outputText
        }

        var fragments: [String] = []
        for item in responseBody.output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for contentItem in content {
                if let type = contentItem["type"] as? String, type == "output_text",
                   let text = contentItem["text"] as? String {
                    fragments.append(text)
                }
            }
        }

        return fragments.isEmpty ? nil : fragments.joined()
    }

    private func finishReason(responseBody: OpenAIResponseBody) -> FinishReason {
        if responseBody.status == "incomplete" {
            return responseBody.incompleteReason == "max_output_tokens" ? .length : .error
        }

        return .stop
    }

    private func usage(responseBody: OpenAIResponseBody) -> Usage? {
        let hasUsage = responseBody.inputTokens != nil || responseBody.outputTokens != nil || responseBody.totalTokens != nil
        guard hasUsage else { return nil }
        return Usage(
            inputTokens: responseBody.inputTokens,
            outputTokens: responseBody.outputTokens,
            totalTokens: responseBody.totalTokens
        )
    }
}

public enum AppleCloudProviderRegistryFactory {
    public static func makeOpenAIRegistry(options: OpenAIProviderOptions) throws -> ProviderRegistry {
        let registry = ProviderRegistry()
        try registry.register(OpenAIProvider(options: options))
        return registry
    }
}

private func serializeJSONObject(_ value: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func parseJSONObject(_ value: String) -> [String: Any] {
    guard let data = value.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data),
          let object = json as? [String: Any] else {
        return [:]
    }
    return object
}

private func parseRetryAfterMs(headers: [String: String]) -> Int? {
    let raw = headers["retry-after"] ?? headers["Retry-After"]
    guard let raw else { return nil }

    if let seconds = Double(raw), seconds.isFinite {
        return max(0, Int(seconds * 1000))
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: raw) else { return nil }
    return max(0, Int(date.timeIntervalSinceNow * 1000))
}
