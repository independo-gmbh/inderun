import Foundation
import IndeRunContracts
import IndeRunCore

public let defaultOpenAIResponsesEndpoint = "https://api.openai.com/v1/responses"

private let defaultHealthCheckTimeoutMs = 3000
private let defaultHealthCheckCacheMs: Int64 = 5000

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
    /// Timeout for the endpoint reachability probe issued from `capabilities()`. Defaults to
    /// 3000ms. The OpenAI API has no dedicated health endpoint, so this is a cheap
    /// unauthenticated `GET` against the configured endpoint.
    public let healthCheckTimeoutMs: Int?
    /// How long a reachability probe result is cached before `capabilities()` re-probes.
    /// Defaults to 5000ms.
    public let healthCheckCacheMs: Int64?

    public init(
        id: String = "openai",
        model: String,
        endpointURL: String = defaultOpenAIResponsesEndpoint,
        auth: OpenAIAuthMode = .authContextRef,
        authContextRef: String? = nil,
        timeoutMs: Int? = nil,
        healthCheckTimeoutMs: Int? = nil,
        healthCheckCacheMs: Int64? = nil
    ) {
        self.id = id
        self.model = model
        self.endpointURL = endpointURL
        self.auth = auth
        self.authContextRef = authContextRef
        self.timeoutMs = timeoutMs
        self.healthCheckTimeoutMs = healthCheckTimeoutMs
        self.healthCheckCacheMs = healthCheckCacheMs
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

public final class OpenAIProvider: StreamingProviderAdapter, @unchecked Sendable {
    private let options: OpenAIProviderOptions
    private let cacheLock = NSLock()
    private var cachedHealth: (result: ProviderDynamicCapabilities, checkedAt: Int64)?

    public init(options: OpenAIProviderOptions) {
        self.options = options
    }

    public func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: options.id,
            type: .cloud,
            transport: .http,
            streamingStyle: .tokens,
            supports: ProviderDescriptor.SupportsCapabilities(
                run: true,
                streaming: true,
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

    /// Reports dynamic provider availability for the current host.
    ///
    /// After the static host-service checks pass, this probes endpoint reachability with a
    /// cheap unauthenticated `GET` against the configured endpoint (the OpenAI API has no
    /// dedicated health endpoint). The result is cached for `healthCheckCacheMs` so routing
    /// decisions and repeated UI capability checks don't re-probe on every call.
    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        guard let httpClient = host.httpClient else {
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

        let reachability = await checkEndpointReachable(httpClient: httpClient, clock: host.clock)
        if host.streamingHttpClient != nil {
            return reachability
        }

        // Mode 1 still works without it; only streaming is taken away, and the
        // planner turns this into an inspectable `streaming_unavailable`
        // rejection rather than an unexplained routing failure.
        return ProviderDynamicCapabilities(
            available: reachability.available,
            reason: reachability.reason,
            streamingAvailable: false,
            streamingUnavailableReason:
                "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires."
        )
    }

    private func checkEndpointReachable(httpClient: any HttpClientService, clock: ClockService?) async -> ProviderDynamicCapabilities {
        let now = clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
        let cacheMs = options.healthCheckCacheMs ?? defaultHealthCheckCacheMs

        if let cached = readCachedHealth(now: now, cacheMs: cacheMs) {
            return cached
        }

        let result: ProviderDynamicCapabilities
        do {
            let response = try await httpClient.send(
                request: HttpRequest(
                    body: nil,
                    headers: nil,
                    method: .get,
                    timeoutMs: options.healthCheckTimeoutMs ?? defaultHealthCheckTimeoutMs,
                    url: options.endpointURL
                )
            )
            result = response.status >= 500
                ? ProviderDynamicCapabilities(
                    available: false,
                    reason: "OpenAI Responses endpoint returned HTTP \(response.status)."
                )
                : ProviderDynamicCapabilities(available: true)
        } catch {
            result = ProviderDynamicCapabilities(
                available: false,
                reason: "OpenAI Responses endpoint is unreachable."
            )
        }

        writeCachedHealth(result: result, checkedAt: now)
        return result
    }

    private func readCachedHealth(now: Int64, cacheMs: Int64) -> ProviderDynamicCapabilities? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cachedHealth, now - cached.checkedAt < cacheMs else {
            return nil
        }
        return cached.result
    }

    private func writeCachedHealth(result: ProviderDynamicCapabilities, checkedAt: Int64) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedHealth = (result, checkedAt)
    }

    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        guard let httpClient = context.hostServices.httpClient else {
            throw createUnavailable(
                message: "OpenAI Responses provider requires an HTTP client.",
                runId: context.runId,
                providerId: options.id
            )
        }

        let headers = try await resolveHeaders(
            request: request,
            hostServices: context.hostServices,
            runId: context.runId
        )

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

    /// Executes a normalized text-to-text task in Mode 2 against the OpenAI
    /// Responses API's server-sent event stream.
    ///
    /// The request is the Mode 1 body plus `"stream": true`, so both modes stay
    /// a single code path up to the transport. The response head is classified
    /// before the body is read: a non-2xx is drained to text and run through the
    /// same `mapHTTPError` as Mode 1, because a 429 must surface as RateLimited
    /// rather than as a malformed event stream.
    ///
    /// Event mapping, from the Responses API's typed SSE events to the canonical
    /// provider vocabulary:
    ///
    /// - `response.output_text.delta` becomes a delta;
    /// - `response.completed` and `response.incomplete` become the terminal done,
    ///   with `finalText`, `usage`, and `finishReason` read off the embedded
    ///   response object by the same helpers Mode 1 uses — it has the same shape;
    /// - `response.failed` and `error` become a terminal failure;
    /// - every other event type is ignored, since the set is open and additive.
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
        guard let streamingClient = context.hostServices.streamingHttpClient else {
            throw createUnavailable(
                message: "OpenAI Responses streaming requires an HttpStreamingClientService.",
                runId: context.runId,
                providerId: options.id
            )
        }

        var headers = try await resolveHeaders(
            request: request,
            hostServices: context.hostServices,
            runId: context.runId
        )
        headers["Accept"] = "text/event-stream"

        let httpRequest = HttpRequest(
            body: try serializeJSONObject(createRequestBody(request: request, stream: true)),
            headers: headers,
            method: .post,
            timeoutMs: options.timeoutMs,
            url: options.endpointURL
        )

        let response: HttpStreamResponse
        do {
            response = try await streamingClient.stream(request: httpRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw createUnavailable(
                message: "OpenAI Responses stream failed before a response was received.",
                runId: context.runId,
                providerId: options.id,
                details: ["originalError": JSONAny(error.localizedDescription)]
            )
        }

        if response.status < 200 || response.status >= 300 {
            var errorBody = Data()
            for try await chunk in response.body {
                errorBody.append(chunk)
            }
            throw mapHTTPError(
                status: response.status,
                statusText: response.statusText,
                headers: response.headers,
                body: String(bytes: errorBody, encoding: .utf8) ?? "",
                runId: context.runId
            )
        }

        var parser = SseParser()
        for try await chunk in response.body {
            if context.cancellation.isCancelled { return }
            for sseEvent in parser.consume(chunk)
            where try emit(sseEvent: sseEvent, context: context, continuation: continuation) {
                return
            }
        }
        for sseEvent in parser.finish()
        where try emit(sseEvent: sseEvent, context: context, continuation: continuation) {
            return
        }

        // Falling out of the loop means the stream ended without a terminal
        // event. The engine reports that as a provider fault; inventing a
        // completion from whatever deltas happened to arrive would hide a
        // truncated response.
    }

    /// Maps one framed SSE event onto the provider vocabulary. Returns true when
    /// the event was terminal and the stream should stop being read.
    private func emit(
        sseEvent: SseEvent,
        context: ProviderStreamContext,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) throws -> Bool {
        if sseEvent.data == "[DONE]" { return false }

        let json = parseJSONObject(sseEvent.data)
        // The `event:` line and the payload's own `type` carry the same value;
        // prefer the payload so a proxy that drops event names still works.
        let type = (json["type"] as? String) ?? sseEvent.event

        switch type {
        case "response.output_text.delta":
            if let delta = json["delta"] as? String {
                continuation.yield(.delta(text: delta))
            }
            return false

        case "response.completed", "response.incomplete":
            let body = OpenAIResponseBody(json: json["response"] as? [String: Any] ?? [:])
            continuation.yield(.done(
                finalText: extractOutputText(responseBody: body) ?? "",
                finishReason: finishReason(responseBody: body),
                usage: usage(responseBody: body)
            ))
            return true

        case "response.failed", "error":
            continuation.yield(.failure(error: mapStreamError(json: json, runId: context.runId)))
            return true

        default:
            return false
        }
    }

    /// Maps a `response.failed` / `error` stream event onto the error taxonomy.
    /// These arrive over an HTTP 200 body, so there is no status code to
    /// classify from; OpenAI reports rate limiting and auth failures here with
    /// the same `code` values it uses in unary error bodies.
    private func mapStreamError(json: [String: Any], runId: String) -> Error {
        let error = (json["error"] as? [String: Any])
            ?? ((json["response"] as? [String: Any])?["error"] as? [String: Any])
            ?? [:]
        let message = error["message"] as? String ?? "OpenAI Responses stream reported a failure."
        let details: [String: JSONAny] = [
            "errorType": JSONAny(error["type"] as? String ?? JSONNull()),
            "errorCode": JSONAny(error["code"] as? String ?? JSONNull())
        ]

        switch error["code"] as? String {
        case "rate_limit_exceeded":
            return createRateLimited(
                message: message, runId: runId, providerId: options.id, retryable: true, details: details
            )
        case "invalid_api_key", "authentication_error":
            return createAuthError(message: message, runId: runId, providerId: options.id, details: details)
        default:
            return createUnavailable(
                message: message, runId: runId, providerId: options.id, retryable: true, details: details
            )
        }
    }

    /// Resolves the request headers, including the bearer token behind
    /// `authContextRef`. Shared by `run` and `stream`: the credential never
    /// travels in the request payload, only the slot id does, so both modes must
    /// resolve it the same way.
    private func resolveHeaders(
        request: TaskRequest,
        hostServices: HostServices,
        runId: String
    ) async throws -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        guard options.auth == .authContextRef else { return headers }

        let slotId = request.authContextRef ?? options.authContextRef
        guard let slotId, !slotId.isEmpty else {
            throw createAuthError(
                message: "OpenAI Responses provider requires authContextRef.",
                runId: runId,
                providerId: options.id
            )
        }

        guard let secureStorage = hostServices.secureStorage else {
            throw createAuthError(
                message: "OpenAI Responses provider requires a SecureStorageService when auth is enabled.",
                runId: runId,
                providerId: options.id
            )
        }

        guard let secret = await secureStorage.getSecret(slotId: slotId), !secret.isEmpty else {
            throw createAuthError(
                message: "No OpenAI credential found for authContextRef '\(slotId)'.",
                runId: runId,
                providerId: options.id
            )
        }

        headers["Authorization"] = "Bearer \(secret)"
        return headers
    }

    private func createRequestBody(request: TaskRequest, stream: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "input": createInput(request: request)
        ]

        if stream {
            body["stream"] = true
        }

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

    private func usage(responseBody: OpenAIResponseBody) -> TaskResultUsage? {
        let hasUsage = responseBody.inputTokens != nil || responseBody.outputTokens != nil || responseBody.totalTokens != nil
        guard hasUsage else { return nil }
        return TaskResultUsage(
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
