// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let taskRequest = try TaskRequest(json)
//   let taskResult = try TaskResult(json)
//   let indeRunError = try IndeRunError(json)
//   let hTTPRequest = try HttpRequest(json)
//   let hTTPResponse = try HttpResponse(json)
//   let telemetryEvent = try TelemetryEvent(json)
//   let routePlannerInput = try RoutePlannerInput(json)
//   let routePlan = try RoutePlan(json)

import Foundation

/// The standard request payload for initiating a text-to-text execution task within the
/// IndeRun framework.
// MARK: - TaskRequest
public struct TaskRequest: Codable, Sendable {
    /// A unique identifier used to retrieve credentials from a secure local storage. Raw
    /// sensitive keys (API keys, etc.) should NEVER be placed directly in the request payload.
    public var authContextRef: String?
    /// Request-level routing constraints used by the planner.
    public var constraints: TaskRequestConstraints?
    /// Optional configuration for fine-tuning how the AI model generates its response.
    public var generation: Generation?
    /// A list of interaction messages for multi-turn conversation or chat-style execution.
    public var messages: [Message]?
    /// Soft routing preferences used for deterministic provider ordering.
    public var preferences: TaskRequestPreferences?
    /// A simple, single-turn text prompt used to trigger a response from the AI model.
    public var prompt: String?
    /// Optional identifier for tracking or correlating this specific execution attempt.
    public var requestId: String?
    /// Contract schema version used to interpret the request payload.
    public var schemaVersion: SchemaVersion
    /// A descriptor specifying the type of work to be performed. For text-to-text, the kind must
    /// be 'text_to_text'.
    public var task: TaskRequestTask
    /// Execution preferences for tracking usage and performance metrics.
    public var telemetry: TaskRequestTelemetry?

    public init(authContextRef: String?, constraints: TaskRequestConstraints?, generation: Generation?, messages: [Message]?, preferences: TaskRequestPreferences?, prompt: String?, requestId: String?, schemaVersion: SchemaVersion, task: TaskRequestTask, telemetry: TaskRequestTelemetry?) {
        self.authContextRef = authContextRef
        self.constraints = constraints
        self.generation = generation
        self.messages = messages
        self.preferences = preferences
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
        constraints: TaskRequestConstraints?? = nil,
        generation: Generation?? = nil,
        messages: [Message]?? = nil,
        preferences: TaskRequestPreferences?? = nil,
        prompt: String?? = nil,
        requestId: String?? = nil,
        schemaVersion: SchemaVersion? = nil,
        task: TaskRequestTask? = nil,
        telemetry: TaskRequestTelemetry?? = nil
    ) -> TaskRequest {
        return TaskRequest(
            authContextRef: authContextRef ?? self.authContextRef,
            constraints: constraints ?? self.constraints,
            generation: generation ?? self.generation,
            messages: messages ?? self.messages,
            preferences: preferences ?? self.preferences,
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

/// Request-level routing constraints used by the planner.
// MARK: - TaskRequestConstraints
public struct TaskRequestConstraints: Codable, Sendable {
    /// Cloud execution constraint.
    public var cloud: Cloud?
    /// Privacy requirement or preference for execution placement.
    public var privacy: PrivacyEnum?
    /// Optional routing timeout budget in milliseconds.
    public var timeoutMs: Int?

    public init(cloud: Cloud?, privacy: PrivacyEnum?, timeoutMs: Int?) {
        self.cloud = cloud
        self.privacy = privacy
        self.timeoutMs = timeoutMs
    }
}

// MARK: TaskRequestConstraints convenience initializers and mutators

public extension TaskRequestConstraints {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskRequestConstraints.self, from: data)
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
        cloud: Cloud?? = nil,
        privacy: PrivacyEnum?? = nil,
        timeoutMs: Int?? = nil
    ) -> TaskRequestConstraints {
        return TaskRequestConstraints(
            cloud: cloud ?? self.cloud,
            privacy: privacy ?? self.privacy,
            timeoutMs: timeoutMs ?? self.timeoutMs
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Cloud execution constraint.
public enum Cloud: String, Codable, Sendable {
    case allowed = "allowed"
    case cloudRequired = "required"
    case forbidden = "forbidden"
}

/// Privacy requirement or preference for execution placement.
public enum PrivacyEnum: String, Codable, Sendable {
    case cloudAllowed = "cloud_allowed"
    case cloudRequired = "cloud_required"
    case localPreferred = "local_preferred"
    case localRequired = "local_required"
}

/// Optional configuration for fine-tuning how the AI model generates its response.
// MARK: - Generation
public struct Generation: Codable, Sendable {
    /// The maximum number of tokens to generate in a single response.
    public var maxOutputTokens: Int?
    /// A fixed seed for deterministic generation (where supported by the underlying provider).
    public var seed: Int?
    /// Sequence tokens that should terminate the generation process.
    public var stop: [String]?
    /// Controls the randomness of the output. Range: 0 (most deterministic) to 2 (highest
    /// variance).
    public var temperature: Double?
    /// Nucleus sampling parameter for controlling diversity vs focus in the output.
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

/// An individual message in a conversation.
// MARK: - Message
public struct Message: Codable, Sendable {
    /// The actual text content of the message.
    public var content: String
    /// The role of the author (e.g., 'user', 'assistant').
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

/// The role of the author (e.g., 'user', 'assistant').
public enum Role: String, Codable, Sendable {
    case assistant = "assistant"
    case system = "system"
    case user = "user"
}

/// Soft routing preferences used for deterministic provider ordering.
// MARK: - TaskRequestPreferences
public struct TaskRequestPreferences: Codable, Sendable {
    /// Primary optimization goal when multiple providers remain eligible.
    public var optimizeFor: OptimizeFor?

    public init(optimizeFor: OptimizeFor?) {
        self.optimizeFor = optimizeFor
    }
}

// MARK: TaskRequestPreferences convenience initializers and mutators

public extension TaskRequestPreferences {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskRequestPreferences.self, from: data)
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
        optimizeFor: OptimizeFor?? = nil
    ) -> TaskRequestPreferences {
        return TaskRequestPreferences(
            optimizeFor: optimizeFor ?? self.optimizeFor
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Primary optimization goal when multiple providers remain eligible.
public enum OptimizeFor: String, Codable, Sendable {
    case balanced = "balanced"
    case cost = "cost"
    case latency = "latency"
    case privacy = "privacy"
}

public enum SchemaVersion: String, Codable, Sendable {
    case the10 = "1.0"
}

/// A descriptor specifying the type of work to be performed. For text-to-text, the kind must
/// be 'text_to_text'.
// MARK: - TaskRequestTask
public struct TaskRequestTask: Codable, Sendable {
    /// The standard task category. Currently supports 'text_to_text' for prompt-based
    /// interactions.
    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: TaskRequestTask convenience initializers and mutators

public extension TaskRequestTask {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskRequestTask.self, from: data)
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
    ) -> TaskRequestTask {
        return TaskRequestTask(
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

/// Execution preferences for tracking usage and performance metrics.
// MARK: - TaskRequestTelemetry
public struct TaskRequestTelemetry: Codable, Sendable {
    /// Whether the user consents to telemetry collection for this specific request.
    public var consent: Bool?
    /// The granularity of the collected metrics (off, minimal, or debug).
    public var level: Level?
    /// Optional key-value pairs for correlating telemetry data with specific features or users.
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

/// The granularity of the collected metrics (off, minimal, or debug).
public enum Level: String, Codable, Sendable {
    case debug = "debug"
    case minimal = "minimal"
    case off = "off"
}

/// The standard response payload for completed text-to-text execution within the IndeRun
/// framework.
// MARK: - TaskResult
public struct TaskResult: Codable, Sendable {
    /// Standardized reason describing how generation concluded (e.g., 'stop', 'length',
    /// 'cancelled', or 'error').
    public var finishReason: FinishReason
    /// The normalized content returned from the selected provider.
    public var output: Output
    /// A unique, opaque identifier assigned by the engine for this specific execution attempt.
    public var runId: String
    /// Contract schema version used to interpret the result payload.
    public var schemaVersion: SchemaVersion
    /// Required metadata providing an overview of the execution result and performance metrics.
    public var telemetry: TaskResultTelemetry
    /// Optional metadata regarding the quantity of tokens processed by the provider.
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

/// Standardized reason describing how generation concluded (e.g., 'stop', 'length',
/// 'cancelled', or 'error').
public enum FinishReason: String, Codable, Sendable {
    case cancelled = "cancelled"
    case error = "error"
    case length = "length"
    case stop = "stop"
}

/// The normalized content returned from the selected provider.
// MARK: - Output
public struct Output: Codable, Sendable {
    /// The actual text generated by the execution.
    public var text: String
    /// Output payload category (e.g., 'text' for Mode 1 text-to-text).
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

/// Required metadata providing an overview of the execution result and performance metrics.
// MARK: - TaskResultTelemetry
public struct TaskResultTelemetry: Codable, Sendable {
    /// Included if the request resulted in a provider-level error (e.g., 'CapabilityMismatch' or
    /// 'Unavailable').
    public var errorClass: ErrorClass?
    /// The identifier for the specific provider that handled the request (e.g.,
    /// 'openai_compatible_cloud').
    public var providerUsed: String
    /// Measured execution duration in milliseconds, including route selection and result
    /// processing.
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

/// Included if the request resulted in a provider-level error (e.g., 'CapabilityMismatch' or
/// 'Unavailable').
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

/// Optional metadata regarding the quantity of tokens processed by the provider.
// MARK: - Usage
public struct Usage: Codable, Sendable {
    /// Number of input tokens consumed, as reported by the provider.
    public var inputTokens: Int?
    /// Number of output tokens generated, as reported by the provider.
    public var outputTokens: Int?
    /// Aggregated token count for this request, as reported by the provider.
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

/// Pure data input contract for deterministic shared-core Mode-1 route planning.
// MARK: - RoutePlannerInput
public struct RoutePlannerInput: Codable, Sendable {
    /// Hard routing constraints evaluated before provider selection.
    public var constraints: RoutePlannerInputConstraints
    /// Soft route ordering preferences applied after hard filtering.
    public var preferences: RoutePlannerInputPreferences
    /// Static descriptors plus dynamic capability snapshots for planning.
    public var providers: [Provider]
    /// Minimal task descriptor for provider task matching.
    public var task: RoutePlannerInputTask

    public init(constraints: RoutePlannerInputConstraints, preferences: RoutePlannerInputPreferences, providers: [Provider], task: RoutePlannerInputTask) {
        self.constraints = constraints
        self.preferences = preferences
        self.providers = providers
        self.task = task
    }
}

// MARK: RoutePlannerInput convenience initializers and mutators

public extension RoutePlannerInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RoutePlannerInput.self, from: data)
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
        constraints: RoutePlannerInputConstraints? = nil,
        preferences: RoutePlannerInputPreferences? = nil,
        providers: [Provider]? = nil,
        task: RoutePlannerInputTask? = nil
    ) -> RoutePlannerInput {
        return RoutePlannerInput(
            constraints: constraints ?? self.constraints,
            preferences: preferences ?? self.preferences,
            providers: providers ?? self.providers,
            task: task ?? self.task
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Hard routing constraints evaluated before provider selection.
// MARK: - RoutePlannerInputConstraints
public struct RoutePlannerInputConstraints: Codable, Sendable {
    /// Cloud execution constraint.
    public var cloud: Cloud?
    /// Current connectivity snapshot used for cloud route planning.
    public var networkOnline: Bool?
    /// Privacy requirement or preference for execution placement.
    public var privacy: PrivacyEnum?

    public init(cloud: Cloud?, networkOnline: Bool?, privacy: PrivacyEnum?) {
        self.cloud = cloud
        self.networkOnline = networkOnline
        self.privacy = privacy
    }
}

// MARK: RoutePlannerInputConstraints convenience initializers and mutators

public extension RoutePlannerInputConstraints {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RoutePlannerInputConstraints.self, from: data)
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
        cloud: Cloud?? = nil,
        networkOnline: Bool?? = nil,
        privacy: PrivacyEnum?? = nil
    ) -> RoutePlannerInputConstraints {
        return RoutePlannerInputConstraints(
            cloud: cloud ?? self.cloud,
            networkOnline: networkOnline ?? self.networkOnline,
            privacy: privacy ?? self.privacy
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Soft route ordering preferences applied after hard filtering.
// MARK: - RoutePlannerInputPreferences
public struct RoutePlannerInputPreferences: Codable, Sendable {
    /// Primary optimization goal when multiple providers remain eligible.
    public var optimizeFor: OptimizeFor?

    public init(optimizeFor: OptimizeFor?) {
        self.optimizeFor = optimizeFor
    }
}

// MARK: RoutePlannerInputPreferences convenience initializers and mutators

public extension RoutePlannerInputPreferences {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RoutePlannerInputPreferences.self, from: data)
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
        optimizeFor: OptimizeFor?? = nil
    ) -> RoutePlannerInputPreferences {
        return RoutePlannerInputPreferences(
            optimizeFor: optimizeFor ?? self.optimizeFor
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Provider
public struct Provider: Codable, Sendable {
    public var capabilities: Capabilities
    public var descriptor: Descriptor

    public init(capabilities: Capabilities, descriptor: Descriptor) {
        self.capabilities = capabilities
        self.descriptor = descriptor
    }
}

// MARK: Provider convenience initializers and mutators

public extension Provider {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Provider.self, from: data)
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
        capabilities: Capabilities? = nil,
        descriptor: Descriptor? = nil
    ) -> Provider {
        return Provider(
            capabilities: capabilities ?? self.capabilities,
            descriptor: descriptor ?? self.descriptor
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Capabilities
public struct Capabilities: Codable, Sendable {
    public var available: Bool
    public var reason: String?

    public init(available: Bool, reason: String?) {
        self.available = available
        self.reason = reason
    }
}

// MARK: Capabilities convenience initializers and mutators

public extension Capabilities {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Capabilities.self, from: data)
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
        available: Bool? = nil,
        reason: String?? = nil
    ) -> Capabilities {
        return Capabilities(
            available: available ?? self.available,
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Descriptor
public struct Descriptor: Codable, Sendable {
    public var id: String
    /// Descriptor privacy metadata used to enforce local/cloud routing rules.
    public var privacy: PrivacyClass?
    public var supports: Supports
    public var tasks: [String]
    public var type: DescriptorType

    public init(id: String, privacy: PrivacyClass?, supports: Supports, tasks: [String], type: DescriptorType) {
        self.id = id
        self.privacy = privacy
        self.supports = supports
        self.tasks = tasks
        self.type = type
    }
}

// MARK: Descriptor convenience initializers and mutators

public extension Descriptor {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Descriptor.self, from: data)
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
        id: String? = nil,
        privacy: PrivacyClass?? = nil,
        supports: Supports? = nil,
        tasks: [String]? = nil,
        type: DescriptorType? = nil
    ) -> Descriptor {
        return Descriptor(
            id: id ?? self.id,
            privacy: privacy ?? self.privacy,
            supports: supports ?? self.supports,
            tasks: tasks ?? self.tasks,
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

/// Descriptor privacy metadata used to enforce local/cloud routing rules.
// MARK: - PrivacyClass
public struct PrivacyClass: Codable, Sendable {
    public var dataLeavesDevice: Bool
    public var regions: [String]?

    public init(dataLeavesDevice: Bool, regions: [String]?) {
        self.dataLeavesDevice = dataLeavesDevice
        self.regions = regions
    }
}

// MARK: PrivacyClass convenience initializers and mutators

public extension PrivacyClass {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PrivacyClass.self, from: data)
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
        dataLeavesDevice: Bool? = nil,
        regions: [String]?? = nil
    ) -> PrivacyClass {
        return PrivacyClass(
            dataLeavesDevice: dataLeavesDevice ?? self.dataLeavesDevice,
            regions: regions ?? self.regions
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Supports
public struct Supports: Codable, Sendable {
    public var run: Bool

    public init(run: Bool) {
        self.run = run
    }
}

// MARK: Supports convenience initializers and mutators

public extension Supports {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Supports.self, from: data)
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
        run: Bool? = nil
    ) -> Supports {
        return Supports(
            run: run ?? self.run
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum DescriptorType: String, Codable, Sendable {
    case cloud = "cloud"
    case edge = "edge"
    case local = "local"
}

/// Minimal task descriptor for provider task matching.
// MARK: - RoutePlannerInputTask
public struct RoutePlannerInputTask: Codable, Sendable {
    public var kind: String

    public init(kind: String) {
        self.kind = kind
    }
}

// MARK: RoutePlannerInputTask convenience initializers and mutators

public extension RoutePlannerInputTask {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RoutePlannerInputTask.self, from: data)
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
        kind: String? = nil
    ) -> RoutePlannerInputTask {
        return RoutePlannerInputTask(
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

/// Deterministic shared-core Mode-1 route planning result.
// MARK: - RoutePlan
public struct RoutePlan: Codable, Sendable {
    /// Eligible candidates in deterministic order.
    public var candidates: [Candidate]
    /// Human-readable selection or failure explanation suitable for telemetry/debugging.
    public var explanation: Explanation
    /// Normalized routing failure class when no provider is selected.
    public var failureCode: FailureCode?
    /// Fallback provider IDs ordered after the primary selection.
    public var fallbackProviderIds: [String]
    /// Providers filtered out during planning together with machine-readable reasons.
    public var rejectedProviders: [RejectedProvider]
    /// Chosen primary provider ID, if any.
    public var selectedProviderId: String?

    public init(candidates: [Candidate], explanation: Explanation, failureCode: FailureCode?, fallbackProviderIds: [String], rejectedProviders: [RejectedProvider], selectedProviderId: String?) {
        self.candidates = candidates
        self.explanation = explanation
        self.failureCode = failureCode
        self.fallbackProviderIds = fallbackProviderIds
        self.rejectedProviders = rejectedProviders
        self.selectedProviderId = selectedProviderId
    }
}

// MARK: RoutePlan convenience initializers and mutators

public extension RoutePlan {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RoutePlan.self, from: data)
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
        candidates: [Candidate]? = nil,
        explanation: Explanation? = nil,
        failureCode: FailureCode?? = nil,
        fallbackProviderIds: [String]? = nil,
        rejectedProviders: [RejectedProvider]? = nil,
        selectedProviderId: String?? = nil
    ) -> RoutePlan {
        return RoutePlan(
            candidates: candidates ?? self.candidates,
            explanation: explanation ?? self.explanation,
            failureCode: failureCode ?? self.failureCode,
            fallbackProviderIds: fallbackProviderIds ?? self.fallbackProviderIds,
            rejectedProviders: rejectedProviders ?? self.rejectedProviders,
            selectedProviderId: selectedProviderId ?? self.selectedProviderId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Candidate
public struct Candidate: Codable, Sendable {
    public var order: Int
    public var providerId: String

    public init(order: Int, providerId: String) {
        self.order = order
        self.providerId = providerId
    }
}

// MARK: Candidate convenience initializers and mutators

public extension Candidate {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Candidate.self, from: data)
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
        order: Int? = nil,
        providerId: String? = nil
    ) -> Candidate {
        return Candidate(
            order: order ?? self.order,
            providerId: providerId ?? self.providerId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Human-readable selection or failure explanation suitable for telemetry/debugging.
// MARK: - Explanation
public struct Explanation: Codable, Sendable {
    public var selectedProviderId: String?
    public var summary: String

    public init(selectedProviderId: String?, summary: String) {
        self.selectedProviderId = selectedProviderId
        self.summary = summary
    }
}

// MARK: Explanation convenience initializers and mutators

public extension Explanation {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Explanation.self, from: data)
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
        selectedProviderId: String?? = nil,
        summary: String? = nil
    ) -> Explanation {
        return Explanation(
            selectedProviderId: selectedProviderId ?? self.selectedProviderId,
            summary: summary ?? self.summary
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Normalized routing failure class when no provider is selected.
public enum FailureCode: String, Codable, Sendable {
    case capabilityMismatch = "capability_mismatch"
    case offline = "offline"
    case unavailable = "unavailable"
}

// MARK: - RejectedProvider
public struct RejectedProvider: Codable, Sendable {
    public var providerId: String
    public var reasons: [Reason]

    public init(providerId: String, reasons: [Reason]) {
        self.providerId = providerId
        self.reasons = reasons
    }
}

// MARK: RejectedProvider convenience initializers and mutators

public extension RejectedProvider {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RejectedProvider.self, from: data)
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
        providerId: String? = nil,
        reasons: [Reason]? = nil
    ) -> RejectedProvider {
        return RejectedProvider(
            providerId: providerId ?? self.providerId,
            reasons: reasons ?? self.reasons
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Reason
public struct Reason: Codable, Sendable {
    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: Reason convenience initializers and mutators

public extension Reason {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Reason.self, from: data)
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
        code: Code? = nil,
        message: String? = nil
    ) -> Reason {
        return Reason(
            code: code ?? self.code,
            message: message ?? self.message
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum Code: String, Codable, Sendable {
    case capabilityUnavailable = "capability_unavailable"
    case cloudConstraint = "cloud_constraint"
    case offline = "offline"
    case privacyConstraint = "privacy_constraint"
    case runNotSupported = "run_not_supported"
    case taskNotSupported = "task_not_supported"
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

    public func hash(into hasher: inout Hasher) {
            hasher.combine(0)
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
