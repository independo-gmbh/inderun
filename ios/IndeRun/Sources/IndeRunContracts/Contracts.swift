// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let taskRequest = try TaskRequest(json)
//   let taskResult = try TaskResult(json)
//   let indeRunError = try IndeRunError(json)
//   let hTTPRequest = try HttpRequest(json)
//   let hTTPResponse = try HttpResponse(json)
//   let telemetryEvent = try TelemetryEvent(json)

import Foundation

/// Milestone-1 text-to-text request contract for Mode 1 run().
// MARK: - TaskRequest
public struct TaskRequest: Codable, Sendable {
    /// Reference to a secure credential slot. Raw credentials must not be placed in the request.
    public var authContextRef: String?
    /// Optional provider-neutral generation hints.
    public var generation: Generation?
    /// Conversation-style text input for chat-like text-to-text execution.
    public var messages: [Message]?
    /// Execution policy constraints used by the router.
    public var policy: Policy
    /// Single text prompt input for simple text-to-text execution.
    public var prompt: String?
    /// Optional caller-provided idempotency/debug identifier for this request.
    public var requestId: String?
    /// Contract schema version used to interpret the request payload.
    public var schemaVersion: SchemaVersion
    /// Task descriptor used by routing and provider capability matching.
    public var task: Task
    /// Caller telemetry preferences for this request.
    public var telemetry: TaskRequestTelemetry?

    public init(authContextRef: String?, generation: Generation?, messages: [Message]?, policy: Policy, prompt: String?, requestId: String?, schemaVersion: SchemaVersion, task: Task, telemetry: TaskRequestTelemetry?) {
        self.authContextRef = authContextRef
        self.generation = generation
        self.messages = messages
        self.policy = policy
        self.prompt = prompt
        self.requestId = requestId
        self.schemaVersion = schemaVersion
        self.task = task
        self.telemetry = telemetry
    }
}

// MARK: TaskRequest convenience initializers and mutators

public extension TaskRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        authContextRef: String?? = nil,
        generation: Generation?? = nil,
        messages: [Message]?? = nil,
        policy: Policy? = nil,
        prompt: String?? = nil,
        requestId: String?? = nil,
        schemaVersion: SchemaVersion? = nil,
        task: Task? = nil,
        telemetry: TaskRequestTelemetry?? = nil
    ) -> TaskRequest {
        return TaskRequest(
            authContextRef: authContextRef ?? self.authContextRef,
            generation: generation ?? self.generation,
            messages: messages ?? self.messages,
            policy: policy ?? self.policy,
            prompt: prompt ?? self.prompt,
            requestId: requestId ?? self.requestId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            task: task ?? self.task,
            telemetry: telemetry ?? self.telemetry
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Optional provider-neutral generation hints.
// MARK: - Generation
public struct Generation: Codable, Sendable {
    /// Optional upper bound for generated output tokens.
    public var maxOutputTokens: Int?
    /// Optional deterministic generation seed when supported by the provider.
    public var seed: Int?
    /// Optional stop sequences that should end generation when matched.
    public var stop: [String]?
    /// Optional randomness hint where 0 is most deterministic and 2 is highest supported
    /// variance.
    public var temperature: Double?
    /// Optional nucleus sampling probability hint.
    public var topP: Double?

    public init(maxOutputTokens: Int?, seed: Int?, stop: [String]?, temperature: Double?, topP: Double?) {
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
        self.stop = stop
        self.temperature = temperature
        self.topP = topP
    }
}

// MARK: Generation convenience initializers and mutators

public extension Generation {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Generation.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        maxOutputTokens: Int?? = nil,
        seed: Int?? = nil,
        stop: [String]?? = nil,
        temperature: Double?? = nil,
        topP: Double?? = nil
    ) -> Generation {
        return Generation(
            maxOutputTokens: maxOutputTokens ?? self.maxOutputTokens,
            seed: seed ?? self.seed,
            stop: stop ?? self.stop,
            temperature: temperature ?? self.temperature,
            topP: topP ?? self.topP
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// One message in the conversation input.
// MARK: - Message
public struct Message: Codable, Sendable {
    /// Text content for this message.
    public var content: String
    /// Role of the message author.
    public var role: Role

    public init(content: String, role: Role) {
        self.content = content
        self.role = role
    }
}

// MARK: Message convenience initializers and mutators

public extension Message {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Message.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        content: String? = nil,
        role: Role? = nil
    ) -> Message {
        return Message(
            content: content ?? self.content,
            role: role ?? self.role
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Role of the message author.
public enum Role: String, Codable, Sendable {
    case assistant = "assistant"
    case system = "system"
    case user = "user"
}

/// Execution policy constraints used by the router.
// MARK: - Policy
public struct Policy: Codable, Sendable {
    /// Required execution target for milestone routing.
    public var execution: Execution

    public init(execution: Execution) {
        self.execution = execution
    }
}

// MARK: Policy convenience initializers and mutators

public extension Policy {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Policy.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        execution: Execution? = nil
    ) -> Policy {
        return Policy(
            execution: execution ?? self.execution
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Required execution target for milestone routing.
public enum Execution: String, Codable, Sendable {
    case cloud = "cloud"
    case onDevice = "on_device"
}

public enum SchemaVersion: String, Codable, Sendable {
    case the10 = "1.0"
}

/// Task descriptor used by routing and provider capability matching.
// MARK: - Task
public struct Task: Codable, Sendable {
    /// Milestone-1 task kind for text input to text output.
    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: Task convenience initializers and mutators

public extension Task {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Task.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        kind: Kind? = nil
    ) -> Task {
        return Task(
            kind: kind ?? self.kind
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum Kind: String, Codable, Sendable {
    case textToText = "text_to_text"
}

/// Caller telemetry preferences for this request.
// MARK: - TaskRequestTelemetry
public struct TaskRequestTelemetry: Codable, Sendable {
    /// Whether the caller consents to telemetry collection for this request.
    public var consent: Bool?
    /// Requested telemetry detail level.
    public var level: Level?
    /// Optional caller-provided non-secret labels for telemetry correlation.
    public var tags: [String: String]?

    public init(consent: Bool?, level: Level?, tags: [String: String]?) {
        self.consent = consent
        self.level = level
        self.tags = tags
    }
}

// MARK: TaskRequestTelemetry convenience initializers and mutators

public extension TaskRequestTelemetry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskRequestTelemetry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        consent: Bool?? = nil,
        level: Level?? = nil,
        tags: [String: String]?? = nil
    ) -> TaskRequestTelemetry {
        return TaskRequestTelemetry(
            consent: consent ?? self.consent,
            level: level ?? self.level,
            tags: tags ?? self.tags
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Requested telemetry detail level.
public enum Level: String, Codable, Sendable {
    case debug = "debug"
    case minimal = "minimal"
    case off = "off"
}

/// Milestone-1 text-to-text result contract for Mode 1 run().
// MARK: - TaskResult
public struct TaskResult: Codable, Sendable {
    /// Normalized reason why generation ended.
    public var finishReason: FinishReason
    /// Normalized text output returned by the selected provider.
    public var output: Output
    /// Opaque run identifier assigned or normalized by the engine.
    public var runId: String
    /// Contract schema version used to interpret the result payload.
    public var schemaVersion: SchemaVersion
    /// Required minimal telemetry summary attached to every result.
    public var telemetry: TaskResultTelemetry
    /// Optional normalized token usage information reported by the provider.
    public var usage: Usage?

    public init(finishReason: FinishReason, output: Output, runId: String, schemaVersion: SchemaVersion, telemetry: TaskResultTelemetry, usage: Usage?) {
        self.finishReason = finishReason
        self.output = output
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.telemetry = telemetry
        self.usage = usage
    }
}

// MARK: TaskResult convenience initializers and mutators

public extension TaskResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskResult.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        finishReason: FinishReason? = nil,
        output: Output? = nil,
        runId: String? = nil,
        schemaVersion: SchemaVersion? = nil,
        telemetry: TaskResultTelemetry? = nil,
        usage: Usage?? = nil
    ) -> TaskResult {
        return TaskResult(
            finishReason: finishReason ?? self.finishReason,
            output: output ?? self.output,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            telemetry: telemetry ?? self.telemetry,
            usage: usage ?? self.usage
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Normalized reason why generation ended.
public enum FinishReason: String, Codable, Sendable {
    case cancelled = "cancelled"
    case error = "error"
    case length = "length"
    case stop = "stop"
}

/// Normalized text output returned by the selected provider.
// MARK: - Output
public struct Output: Codable, Sendable {
    /// Generated text returned to the caller.
    public var text: String
    /// Output payload kind for milestone text-to-text execution.
    public var type: OutputType

    public init(text: String, type: OutputType) {
        self.text = text
        self.type = type
    }
}

// MARK: Output convenience initializers and mutators

public extension Output {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Output.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        text: String? = nil,
        type: OutputType? = nil
    ) -> Output {
        return Output(
            text: text ?? self.text,
            type: type ?? self.type
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum OutputType: String, Codable, Sendable {
    case text = "text"
}

/// Required minimal telemetry summary attached to every result.
// MARK: - TaskResultTelemetry
public struct TaskResultTelemetry: Codable, Sendable {
    /// Optional normalized error class if the result represents a provider-level error outcome.
    public var errorClass: ErrorClass?
    /// Identifier of the provider selected for the completed attempt.
    public var providerUsed: String
    /// Total measured execution duration in milliseconds.
    public var totalMs: Double

    public init(errorClass: ErrorClass?, providerUsed: String, totalMs: Double) {
        self.errorClass = errorClass
        self.providerUsed = providerUsed
        self.totalMs = totalMs
    }
}

// MARK: TaskResultTelemetry convenience initializers and mutators

public extension TaskResultTelemetry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskResultTelemetry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        errorClass: ErrorClass?? = nil,
        providerUsed: String? = nil,
        totalMs: Double? = nil
    ) -> TaskResultTelemetry {
        return TaskResultTelemetry(
            errorClass: errorClass ?? self.errorClass,
            providerUsed: providerUsed ?? self.providerUsed,
            totalMs: totalMs ?? self.totalMs
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Optional normalized error class if the result represents a provider-level error outcome.
///
/// Normalized error taxonomy class.
public enum ErrorClass: String, Codable, Sendable {
    case AuthError = "AuthError"
    case CapabilityMismatch = "CapabilityMismatch"
    case Internal = "Internal"
    case Offline = "Offline"
    case RateLimited = "RateLimited"
    case Timeout = "Timeout"
    case Unavailable = "Unavailable"
}

/// Optional normalized token usage information reported by the provider.
// MARK: - Usage
public struct Usage: Codable, Sendable {
    /// Number of input tokens consumed, when reported by the provider.
    public var inputTokens: Int?
    /// Number of output tokens generated, when reported by the provider.
    public var outputTokens: Int?
    /// Total token count, when reported by the provider.
    public var totalTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

// MARK: Usage convenience initializers and mutators

public extension Usage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Usage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        inputTokens: Int?? = nil,
        outputTokens: Int?? = nil,
        totalTokens: Int?? = nil
    ) -> Usage {
        return Usage(
            inputTokens: inputTokens ?? self.inputTokens,
            outputTokens: outputTokens ?? self.outputTokens,
            totalTokens: totalTokens ?? self.totalTokens
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Normalized Milestone-1 error contract.
// MARK: - IndeRunError
public struct IndeRunError: Codable, Sendable {
    /// Optional structured diagnostic details. It must not contain raw secrets.
    public var details: [String: JSONAny]?
    /// Normalized error taxonomy class.
    public var errorClass: ErrorClass
    /// Human-readable error message suitable for logs and developer diagnostics.
    public var message: String
    /// Identifier of the provider associated with the failure, if execution reached a provider.
    public var providerId: String?
    /// Whether retrying the same request may succeed.
    public var retryable: Bool?
    /// Optional suggested delay before retrying, in milliseconds.
    public var retryAfterMs: Int?
    /// Opaque run identifier associated with the failed execution, if available.
    public var runId: String?
    /// Contract schema version used to interpret the error payload.
    public var schemaVersion: SchemaVersion

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, providerId: String?, retryable: Bool?, retryAfterMs: Int?, runId: String?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.providerId = providerId
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.runId = runId
        self.schemaVersion = schemaVersion
    }
}

// MARK: IndeRunError convenience initializers and mutators

public extension IndeRunError {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(IndeRunError.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        details: [String: JSONAny]?? = nil,
        errorClass: ErrorClass? = nil,
        message: String? = nil,
        providerId: String?? = nil,
        retryable: Bool?? = nil,
        retryAfterMs: Int?? = nil,
        runId: String?? = nil,
        schemaVersion: SchemaVersion? = nil
    ) -> IndeRunError {
        return IndeRunError(
            details: details ?? self.details,
            errorClass: errorClass ?? self.errorClass,
            message: message ?? self.message,
            providerId: providerId ?? self.providerId,
            retryable: retryable ?? self.retryable,
            retryAfterMs: retryAfterMs ?? self.retryAfterMs,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Normalized HTTP request payload for host-provided cloud transport.
// MARK: - HttpRequest
public struct HttpRequest: Codable, Sendable {
    /// Optional serialized request body. For JSON APIs this should be a JSON string.
    public var body: String?
    /// HTTP headers to send after the provider adapter has applied any required transport-level
    /// credentials.
    public var headers: [String: String]?
    /// HTTP method to use for the request.
    public var method: Method
    /// Optional maximum duration for the host transport attempt in milliseconds.
    public var timeoutMs: Int?
    /// Absolute target URL for the provider transport request.
    public var url: String

    public init(body: String?, headers: [String: String]?, method: Method, timeoutMs: Int?, url: String) {
        self.body = body
        self.headers = headers
        self.method = method
        self.timeoutMs = timeoutMs
        self.url = url
    }
}

// MARK: HttpRequest convenience initializers and mutators

public extension HttpRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(HttpRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        body: String?? = nil,
        headers: [String: String]?? = nil,
        method: Method? = nil,
        timeoutMs: Int?? = nil,
        url: String? = nil
    ) -> HttpRequest {
        return HttpRequest(
            body: body ?? self.body,
            headers: headers ?? self.headers,
            method: method ?? self.method,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// HTTP method to use for the request.
public enum Method: String, Codable, Sendable {
    case delete = "DELETE"
    case get = "GET"
    case patch = "PATCH"
    case post = "POST"
    case put = "PUT"
}

/// Normalized HTTP response payload returned by host-provided cloud transport.
// MARK: - HttpResponse
public struct HttpResponse: Codable, Sendable {
    /// Serialized response body returned by the provider transport.
    public var body: String
    /// HTTP response headers normalized to string key-value pairs.
    public var headers: [String: String]
    /// HTTP status code returned by the provider transport.
    public var status: Int
    /// HTTP status text returned by the provider transport.
    public var statusText: String

    public init(body: String, headers: [String: String], status: Int, statusText: String) {
        self.body = body
        self.headers = headers
        self.status = status
        self.statusText = statusText
    }
}

// MARK: HttpResponse convenience initializers and mutators

public extension HttpResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(HttpResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        body: String? = nil,
        headers: [String: String]? = nil,
        status: Int? = nil,
        statusText: String? = nil
    ) -> HttpResponse {
        return HttpResponse(
            body: body ?? self.body,
            headers: headers ?? self.headers,
            status: status ?? self.status,
            statusText: statusText ?? self.statusText
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Normalized telemetry event emitted by the orchestrator and providers.
// MARK: - TelemetryEvent
public struct TelemetryEvent: Codable, Sendable {
    /// Event-specific metadata. It must not contain prompt payloads or raw secrets.
    public var payload: [String: JSONAny]
    /// Opaque run identifier associated with this execution event.
    public var runId: String
    /// Wall-clock event timestamp in Unix epoch milliseconds.
    public var timestamp: Double
    /// Telemetry event kind emitted by the orchestrator or provider integration.
    public var type: TelemetryEventType

    public init(payload: [String: JSONAny], runId: String, timestamp: Double, type: TelemetryEventType) {
        self.payload = payload
        self.runId = runId
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: TelemetryEvent convenience initializers and mutators

public extension TelemetryEvent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TelemetryEvent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        payload: [String: JSONAny]? = nil,
        runId: String? = nil,
        timestamp: Double? = nil,
        type: TelemetryEventType? = nil
    ) -> TelemetryEvent {
        return TelemetryEvent(
            payload: payload ?? self.payload,
            runId: runId ?? self.runId,
            timestamp: timestamp ?? self.timestamp,
            type: type ?? self.type
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Telemetry event kind emitted by the orchestrator or provider integration.
public enum TelemetryEventType: String, Codable, Sendable {
    case attemptFailed = "attempt_failed"
    case attemptSucceeded = "attempt_succeeded"
    case routeDecided = "route_decided"
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}

// MARK: - Encode/decode helpers

public class JSONNull: Codable, Hashable {

    public static func == (lhs: JSONNull, rhs: JSONNull) -> Bool {
            return true
    }

    public var hashValue: Int {
            return 0
    }

    public init() {}

    public required init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if !container.decodeNil() {
                    throw DecodingError.typeMismatch(JSONNull.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONNull"))
            }
    }

    public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
    }
}

class JSONCodingKey: CodingKey {
    let key: String

    required init?(intValue: Int) {
            return nil
    }

    required init?(stringValue: String) {
            key = stringValue
    }

    var intValue: Int? {
            return nil
    }

    var stringValue: String {
            return key
    }
}

public class JSONAny: Codable {

    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    static func decodingError(forCodingPath codingPath: [CodingKey]) -> DecodingError {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode JSONAny")
            return DecodingError.typeMismatch(JSONAny.self, context)
    }

    static func encodingError(forValue value: Any, codingPath: [CodingKey]) -> EncodingError {
            let context = EncodingError.Context(codingPath: codingPath, debugDescription: "Cannot encode JSONAny")
            return EncodingError.invalidValue(value, context)
    }

    static func decode(from container: SingleValueDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if container.decodeNil() {
                    return JSONNull()
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout UnkeyedDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if let value = try? container.decodeNil() {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer() {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout KeyedDecodingContainer<JSONCodingKey>, forKey key: JSONCodingKey) throws -> Any {
            if let value = try? container.decode(Bool.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Int64.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(String.self, forKey: key) {
                    return value
            }
            if let value = try? container.decodeNil(forKey: key) {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer(forKey: key) {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decodeArray(from container: inout UnkeyedDecodingContainer) throws -> [Any] {
            var arr: [Any] = []
            while !container.isAtEnd {
                    let value = try decode(from: &container)
                    arr.append(value)
            }
            return arr
    }

    static func decodeDictionary(from container: inout KeyedDecodingContainer<JSONCodingKey>) throws -> [String: Any] {
            var dict = [String: Any]()
            for key in container.allKeys {
                    let value = try decode(from: &container, forKey: key)
                    dict[key.stringValue] = value
            }
            return dict
    }

    static func encode(to container: inout UnkeyedEncodingContainer, array: [Any]) throws {
            for value in array {
                    if let value = value as? Bool {
                            try container.encode(value)
                    } else if let value = value as? Int64 {
                            try container.encode(value)
                    } else if let value = value as? Double {
                            try container.encode(value)
                    } else if let value = value as? String {
                            try container.encode(value)
                    } else if value is JSONNull {
                            try container.encodeNil()
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer()
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout KeyedEncodingContainer<JSONCodingKey>, dictionary: [String: Any]) throws {
            for (key, value) in dictionary {
                    let key = JSONCodingKey(stringValue: key)!
                    if let value = value as? Bool {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Int64 {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Double {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? String {
                            try container.encode(value, forKey: key)
                    } else if value is JSONNull {
                            try container.encodeNil(forKey: key)
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer(forKey: key)
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout SingleValueEncodingContainer, value: Any) throws {
            if let value = value as? Bool {
                    try container.encode(value)
            } else if let value = value as? Int64 {
                    try container.encode(value)
            } else if let value = value as? Double {
                    try container.encode(value)
            } else if let value = value as? String {
                    try container.encode(value)
            } else if value is JSONNull {
                    try container.encodeNil()
            } else {
                    throw encodingError(forValue: value, codingPath: container.codingPath)
            }
    }

    public required init(from decoder: Decoder) throws {
            if var arrayContainer = try? decoder.unkeyedContainer() {
                    self.value = try JSONAny.decodeArray(from: &arrayContainer)
            } else if var container = try? decoder.container(keyedBy: JSONCodingKey.self) {
                    self.value = try JSONAny.decodeDictionary(from: &container)
            } else {
                    let container = try decoder.singleValueContainer()
                    self.value = try JSONAny.decode(from: container)
            }
    }

    public func encode(to encoder: Encoder) throws {
            if let arr = self.value as? [Any] {
                    var container = encoder.unkeyedContainer()
                    try JSONAny.encode(to: &container, array: arr)
            } else if let dict = self.value as? [String: Any] {
                    var container = encoder.container(keyedBy: JSONCodingKey.self)
                    try JSONAny.encode(to: &container, dictionary: dict)
            } else {
                    var container = encoder.singleValueContainer()
                    try JSONAny.encode(to: &container, value: self.value)
            }
    }
}
