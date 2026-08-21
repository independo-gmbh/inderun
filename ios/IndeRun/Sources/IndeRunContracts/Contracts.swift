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
//   let modelPackage = try ModelPackage(json)
//   let streamRunHandle = try StreamRunHandle(json)
//   let streamEvent = try StreamEvent(json)
//   let streamTerminalOutcome = try StreamTerminalOutcome(json)

import Foundation

/// The request payload for a Mode 1 (request/response) text-to-text execution. At least one
/// of `prompt` (single-turn) or `messages` (multi-turn) must be present — both may be
/// present together, though callers should typically supply just one;
/// `constraints`/`preferences` steer routing but never select a provider directly.
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

    public enum CodingKeys: String, CodingKey {
        case authContextRef = "authContextRef"
        case constraints = "constraints"
        case generation = "generation"
        case messages = "messages"
        case preferences = "preferences"
        case prompt = "prompt"
        case requestId = "requestId"
        case schemaVersion = "schemaVersion"
        case task = "task"
        case telemetry = "telemetry"
    }

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

    public enum CodingKeys: String, CodingKey {
        case cloud = "cloud"
        case privacy = "privacy"
        case timeoutMs = "timeoutMs"
    }

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

    public enum CodingKeys: String, CodingKey {
        case maxOutputTokens = "maxOutputTokens"
        case seed = "seed"
        case stop = "stop"
        case temperature = "temperature"
        case topP = "topP"
    }

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

    public enum CodingKeys: String, CodingKey {
        case content = "content"
        case role = "role"
    }

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

    public enum CodingKeys: String, CodingKey {
        case optimizeFor = "optimizeFor"
    }

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

    public enum CodingKeys: String, CodingKey {
        case kind = "kind"
    }

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

    public enum CodingKeys: String, CodingKey {
        case consent = "consent"
        case level = "level"
        case tags = "tags"
    }

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

/// The response payload for a completed text-to-text execution. A full execution failure
/// (validation, routing, or every attempted provider failing) is surfaced by run() throwing
/// an IndeRunError instead of returning a TaskResult; finishReason and telemetry.errorClass
/// are reserved for a provider reporting a non-fatal, degraded outcome on an
/// otherwise-successful result (not currently produced by any provider in this codebase).
// MARK: - TaskResult
public struct TaskResult: Codable, Sendable {
    /// How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
    /// 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
    /// otherwise-returned result — no provider in this codebase currently produces it, since a
    /// full execution failure is instead surfaced by run() throwing an IndeRunError.
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
    public var usage: TaskResultUsage?

    public enum CodingKeys: String, CodingKey {
        case finishReason = "finishReason"
        case output = "output"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
    }

    public init(finishReason: FinishReason, output: Output, runId: String, schemaVersion: SchemaVersion, telemetry: TaskResultTelemetry, usage: TaskResultUsage?) {
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
        usage: TaskResultUsage?? = nil
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

/// How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
/// 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
/// otherwise-returned result — no provider in this codebase currently produces it, since a
/// full execution failure is instead surfaced by run() throwing an IndeRunError.
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

    public enum CodingKeys: String, CodingKey {
        case text = "text"
        case type = "type"
    }

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
    /// Present only if a provider reports a degraded outcome on an otherwise-successful result;
    /// no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
    /// IndeRunError never produces a TaskResult at all.
    public var errorClass: ErrorClass?
    /// The identifier for the specific provider that handled the request (e.g.,
    /// 'openai_compatible_cloud').
    public var providerUsed: String
    /// Measured execution duration in milliseconds, including route selection and result
    /// processing.
    public var totalMs: Double

    public enum CodingKeys: String, CodingKey {
        case errorClass = "errorClass"
        case providerUsed = "providerUsed"
        case totalMs = "totalMs"
    }

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

/// Present only if a provider reports a degraded outcome on an otherwise-successful result;
/// no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
/// IndeRunError never produces a TaskResult at all.
///
/// Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
/// CapabilityMismatch (request needs something no eligible provider supports),
/// Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
/// failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
/// execution budget), Internal (unexpected engine-side failure).
///
/// Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
/// (request needs something no eligible provider supports), Offline/Unavailable (provider
/// unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
/// throttled the request), Timeout (provider exceeded its execution budget), Internal
/// (unexpected engine-side failure).
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
// MARK: - TaskResultUsage
public struct TaskResultUsage: Codable, Sendable {
    /// Number of input tokens consumed, as reported by the provider.
    public var inputTokens: Int?
    /// Number of output tokens generated, as reported by the provider.
    public var outputTokens: Int?
    /// Aggregated token count for this request, as reported by the provider.
    public var totalTokens: Int?

    public enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case totalTokens = "totalTokens"
    }

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

// MARK: TaskResultUsage convenience initializers and mutators

public extension TaskResultUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskResultUsage.self, from: data)
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
    ) -> TaskResultUsage {
        return TaskResultUsage(
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

/// The error shape thrown by run() (wrapped in an IndeRunException) when execution fails —
/// via validation, routing (no eligible provider), or every attempted provider failing.
/// Never returned as part of a successful TaskResult.
// MARK: - IndeRunError
public struct IndeRunError: Codable, Sendable {
    /// Optional structured diagnostic details. It must not contain raw secrets.
    public var details: [String: JSONAny]?
    /// Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
    /// CapabilityMismatch (request needs something no eligible provider supports),
    /// Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
    /// failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
    /// execution budget), Internal (unexpected engine-side failure).
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

    public enum CodingKeys: String, CodingKey {
        case details = "details"
        case errorClass = "errorClass"
        case message = "message"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
    }

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

    public enum CodingKeys: String, CodingKey {
        case body = "body"
        case headers = "headers"
        case method = "method"
        case timeoutMs = "timeoutMs"
        case url = "url"
    }

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

    public enum CodingKeys: String, CodingKey {
        case body = "body"
        case headers = "headers"
        case status = "status"
        case statusText = "statusText"
    }

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

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case runId = "runId"
        case timestamp = "timestamp"
        case type = "type"
    }

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

    public enum CodingKeys: String, CodingKey {
        case constraints = "constraints"
        case preferences = "preferences"
        case providers = "providers"
        case task = "task"
    }

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

    public enum CodingKeys: String, CodingKey {
        case cloud = "cloud"
        case networkOnline = "networkOnline"
        case privacy = "privacy"
    }

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

    public enum CodingKeys: String, CodingKey {
        case optimizeFor = "optimizeFor"
    }

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

    public enum CodingKeys: String, CodingKey {
        case capabilities = "capabilities"
        case descriptor = "descriptor"
    }

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

    public enum CodingKeys: String, CodingKey {
        case available = "available"
        case reason = "reason"
    }

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

    public enum CodingKeys: String, CodingKey {
        case id = "id"
        case privacy = "privacy"
        case supports = "supports"
        case tasks = "tasks"
        case type = "type"
    }

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

    public enum CodingKeys: String, CodingKey {
        case dataLeavesDevice = "dataLeavesDevice"
        case regions = "regions"
    }

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

    public enum CodingKeys: String, CodingKey {
        case run = "run"
    }

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

    public enum CodingKeys: String, CodingKey {
        case kind = "kind"
    }

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

    public enum CodingKeys: String, CodingKey {
        case candidates = "candidates"
        case explanation = "explanation"
        case failureCode = "failureCode"
        case fallbackProviderIds = "fallbackProviderIds"
        case rejectedProviders = "rejectedProviders"
        case selectedProviderId = "selectedProviderId"
    }

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

    public enum CodingKeys: String, CodingKey {
        case order = "order"
        case providerId = "providerId"
    }

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

    public enum CodingKeys: String, CodingKey {
        case selectedProviderId = "selectedProviderId"
        case summary = "summary"
    }

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

    public enum CodingKeys: String, CodingKey {
        case providerId = "providerId"
        case reasons = "reasons"
    }

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

    public enum CodingKeys: String, CodingKey {
        case code = "code"
        case message = "message"
    }

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

/// Provider-neutral descriptor for a developer-supplied/custom local model made available to
/// an IndeRun local-model provider family (for example, the ONNX Runtime family). It
/// describes model identity, format, task support, source, files, integrity, licensing, and
/// resource expectations. It is bootstrap/configuration metadata resolved before execution;
/// it is not part of the public TaskRequest/TaskResult surface, and it must not carry raw
/// secrets.
// MARK: - ModelPackage
public struct ModelPackage: Codable, Sendable {
    /// Files that make up the model package, expressed as source-relative names/paths. The
    /// provider adapter and model source resolve these to concrete bytes per platform.
    public var files: Files?
    /// Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
    /// graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
    /// model package.
    public var format: Format
    /// Stable application-scoped identifier for the model package.
    public var id: String
    /// Optional integrity metadata used to validate resolved files before load.
    public var integrity: Integrity?
    /// Optional license/source metadata for the model, for developer transparency. Free-form.
    public var license: License?
    /// Optional known resource expectations, used by capability checks to reject on constrained
    /// devices before load.
    public var limits: Limits?
    /// Optional runtime compatibility expectations. Fields are advisory hints for capability
    /// checks; the provider adapter owns exact enforcement.
    public var runtime: Runtime?
    /// Where the model files are obtained from. Availability of each source type is
    /// platform-dependent; see the ONNX Runtime provider-family specification for the
    /// per-platform support matrix.
    public var source: Source?
    /// IndeRun task kinds this model package can serve (for example 'text_to_text'). Used by
    /// dynamic capability checks and route matching.
    public var tasks: [String]?
    /// Optional application-defined version for the model package, used for cache invalidation
    /// and compatibility checks.
    public var version: String?

    public enum CodingKeys: String, CodingKey {
        case files = "files"
        case format = "format"
        case id = "id"
        case integrity = "integrity"
        case license = "license"
        case limits = "limits"
        case runtime = "runtime"
        case source = "source"
        case tasks = "tasks"
        case version = "version"
    }

    public init(files: Files?, format: Format, id: String, integrity: Integrity?, license: License?, limits: Limits?, runtime: Runtime?, source: Source?, tasks: [String]?, version: String?) {
        self.files = files
        self.format = format
        self.id = id
        self.integrity = integrity
        self.license = license
        self.limits = limits
        self.runtime = runtime
        self.source = source
        self.tasks = tasks
        self.version = version
    }
}

// MARK: ModelPackage convenience initializers and mutators

public extension ModelPackage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ModelPackage.self, from: data)
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
        files: Files?? = nil,
        format: Format? = nil,
        id: String? = nil,
        integrity: Integrity?? = nil,
        license: License?? = nil,
        limits: Limits?? = nil,
        runtime: Runtime?? = nil,
        source: Source?? = nil,
        tasks: [String]?? = nil,
        version: String?? = nil
    ) -> ModelPackage {
        return ModelPackage(
            files: files ?? self.files,
            format: format ?? self.format,
            id: id ?? self.id,
            integrity: integrity ?? self.integrity,
            license: license ?? self.license,
            limits: limits ?? self.limits,
            runtime: runtime ?? self.runtime,
            source: source ?? self.source,
            tasks: tasks ?? self.tasks,
            version: version ?? self.version
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Files that make up the model package, expressed as source-relative names/paths. The
/// provider adapter and model source resolve these to concrete bytes per platform.
// MARK: - Files
public struct Files: Codable, Sendable {
    /// Optional model/generation config file, where the model requires one.
    public var config: String?
    /// Optional external data files referenced by the model graph (for example ONNX external
    /// weights).
    public var external: [String]?
    /// Files that must be present for the package to load (for example the model graph).
    public var filesRequired: [String]?
    /// Optional tokenizer file, where the model requires one.
    public var tokenizer: String?

    public enum CodingKeys: String, CodingKey {
        case config = "config"
        case external = "external"
        case filesRequired = "required"
        case tokenizer = "tokenizer"
    }

    public init(config: String?, external: [String]?, filesRequired: [String]?, tokenizer: String?) {
        self.config = config
        self.external = external
        self.filesRequired = filesRequired
        self.tokenizer = tokenizer
    }
}

// MARK: Files convenience initializers and mutators

public extension Files {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Files.self, from: data)
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
        config: String?? = nil,
        external: [String]?? = nil,
        filesRequired: [String]?? = nil,
        tokenizer: String?? = nil
    ) -> Files {
        return Files(
            config: config ?? self.config,
            external: external ?? self.external,
            filesRequired: filesRequired ?? self.filesRequired,
            tokenizer: tokenizer ?? self.tokenizer
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
/// graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
/// model package.
public enum Format: String, Codable, Sendable {
    case genai = "genai"
    case onnx = "onnx"
    case ort = "ort"
}

/// Optional integrity metadata used to validate resolved files before load.
// MARK: - Integrity
public struct Integrity: Codable, Sendable {
    /// Map of file name to expected checksum (for example 'sha256:...'). Absence means integrity
    /// is not verified by IndeRun.
    public var checksums: [String: String]?

    public enum CodingKeys: String, CodingKey {
        case checksums = "checksums"
    }

    public init(checksums: [String: String]?) {
        self.checksums = checksums
    }
}

// MARK: Integrity convenience initializers and mutators

public extension Integrity {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Integrity.self, from: data)
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
        checksums: [String: String]?? = nil
    ) -> Integrity {
        return Integrity(
            checksums: checksums ?? self.checksums
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Optional license/source metadata for the model, for developer transparency. Free-form.
// MARK: - License
public struct License: Codable, Sendable {
    /// SPDX license identifier where known (for example 'Apache-2.0').
    public var spdx: String?
    /// License or model card URL where available.
    public var url: String?

    public enum CodingKeys: String, CodingKey {
        case spdx = "spdx"
        case url = "url"
    }

    public init(spdx: String?, url: String?) {
        self.spdx = spdx
        self.url = url
    }
}

// MARK: License convenience initializers and mutators

public extension License {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(License.self, from: data)
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
        spdx: String?? = nil,
        url: String?? = nil
    ) -> License {
        return License(
            spdx: spdx ?? self.spdx,
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

/// Optional known resource expectations, used by capability checks to reject on constrained
/// devices before load.
// MARK: - Limits
public struct Limits: Codable, Sendable {
    /// Approximate on-disk size of the resolved package, where known.
    public var diskBytes: Int?
    /// Approximate peak memory required to run the model, where known.
    public var memBytes: Int?

    public enum CodingKeys: String, CodingKey {
        case diskBytes = "diskBytes"
        case memBytes = "memBytes"
    }

    public init(diskBytes: Int?, memBytes: Int?) {
        self.diskBytes = diskBytes
        self.memBytes = memBytes
    }
}

// MARK: Limits convenience initializers and mutators

public extension Limits {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Limits.self, from: data)
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
        diskBytes: Int?? = nil,
        memBytes: Int?? = nil
    ) -> Limits {
        return Limits(
            diskBytes: diskBytes ?? self.diskBytes,
            memBytes: memBytes ?? self.memBytes
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Optional runtime compatibility expectations. Fields are advisory hints for capability
/// checks; the provider adapter owns exact enforcement.
// MARK: - Runtime
public struct Runtime: Codable, Sendable {
    /// Minimum ONNX opset version the model requires, where known.
    public var minOpset: Int?
    /// Minimum runtime package version required to load the model, where known.
    public var minRuntimeVersion: String?
    /// Platforms the package is expected to run on (for example 'web', 'android', 'apple').
    /// Absence means unconstrained.
    public var platforms: [String]?

    public enum CodingKeys: String, CodingKey {
        case minOpset = "minOpset"
        case minRuntimeVersion = "minRuntimeVersion"
        case platforms = "platforms"
    }

    public init(minOpset: Int?, minRuntimeVersion: String?, platforms: [String]?) {
        self.minOpset = minOpset
        self.minRuntimeVersion = minRuntimeVersion
        self.platforms = platforms
    }
}

// MARK: Runtime convenience initializers and mutators

public extension Runtime {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Runtime.self, from: data)
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
        minOpset: Int?? = nil,
        minRuntimeVersion: String?? = nil,
        platforms: [String]?? = nil
    ) -> Runtime {
        return Runtime(
            minOpset: minOpset ?? self.minOpset,
            minRuntimeVersion: minRuntimeVersion ?? self.minRuntimeVersion,
            platforms: platforms ?? self.platforms
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Where the model files are obtained from. Availability of each source type is
/// platform-dependent; see the ONNX Runtime provider-family specification for the
/// per-platform support matrix.
// MARK: - Source
public struct Source: Codable, Sendable {
    /// Optional source-specific reference (for example a registry repo id or a bundled asset
    /// base path). Interpretation depends on 'sourceType'. Must not contain credentials: URL
    /// userinfo (for example 'https://user:pass@host/...') is rejected, and credentials must be
    /// supplied via authContextRef instead.
    public var ref: String?
    /// Discriminator for how the host makes model files available. 'registry' is a web
    /// repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
    /// app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
    /// is a local path where the platform allows it, 'app_managed' is an app-managed
    /// cache/storage location, 'remote' is a host-managed download.
    public var sourceType: SourceType

    public enum CodingKeys: String, CodingKey {
        case ref = "ref"
        case sourceType = "sourceType"
    }

    public init(ref: String?, sourceType: SourceType) {
        self.ref = ref
        self.sourceType = sourceType
    }
}

// MARK: Source convenience initializers and mutators

public extension Source {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Source.self, from: data)
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
        ref: String?? = nil,
        sourceType: SourceType? = nil
    ) -> Source {
        return Source(
            ref: ref ?? self.ref,
            sourceType: sourceType ?? self.sourceType
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Discriminator for how the host makes model files available. 'registry' is a web
/// repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
/// app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
/// is a local path where the platform allows it, 'app_managed' is an app-managed
/// cache/storage location, 'remote' is a host-managed download.
public enum SourceType: String, Codable, Sendable {
    case appManaged = "app_managed"
    case bundled = "bundled"
    case filesystem = "filesystem"
    case programmatic = "programmatic"
    case registry = "registry"
    case remote = "remote"
}

/// The serializable acknowledgment returned when a Mode 2 stream is opened, before any
/// StreamEvent has arrived. This is the identity/correlation contract only: the live,
/// consumable stream itself is a platform-idiomatic construct (an AsyncIterable<StreamEvent>
/// in TypeScript, a Flow<StreamEvent> in Kotlin, an AsyncThrowingStream<StreamEvent, Error>
/// in Swift) that is never serialized and is out of scope for this schema. Design seam only;
/// no engine or provider implementation exists yet (see docs/architecture/architecture.md).
// MARK: - StreamRunHandle
public struct StreamRunHandle: Codable, Sendable {
    /// Identifier of the provider selected to service this stream, if routing has completed by
    /// the time the handle is returned. Absent while route selection is still pending.
    public var providerId: String?
    /// A unique, opaque identifier assigned by the engine for this stream run. Every StreamEvent
    /// and the terminal StreamTerminalOutcome for this run carry the same runId, matching the
    /// identity convention used by TaskResult.runId and IndeRunError.runId.
    public var runId: String
    /// Contract schema version used to interpret this handle payload.
    public var schemaVersion: SchemaVersion
    /// Wall-clock time the stream run was opened, in Unix epoch milliseconds.
    public var startedAt: Double

    public enum CodingKeys: String, CodingKey {
        case providerId = "providerId"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case startedAt = "startedAt"
    }

    public init(providerId: String?, runId: String, schemaVersion: SchemaVersion, startedAt: Double) {
        self.providerId = providerId
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
    }
}

// MARK: StreamRunHandle convenience initializers and mutators

public extension StreamRunHandle {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamRunHandle.self, from: data)
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
        providerId: String?? = nil,
        runId: String? = nil,
        schemaVersion: SchemaVersion? = nil,
        startedAt: Double? = nil
    ) -> StreamRunHandle {
        return StreamRunHandle(
            providerId: providerId ?? self.providerId,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            startedAt: startedAt ?? self.startedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The canonical Mode 2 streaming event union, discriminated by 'type'. Every variant shares
/// an envelope of schemaVersion, runId, sequence, timestamp, and type. 'sequence' is the
/// ordering authority for events within a run (a monotonically increasing integer starting
/// at 0 per runId) — consumers must order by 'sequence', not by arrival order, since a
/// bridge hop (e.g. a future Capacitor bridge) could reorder delivery. Known event types are
/// split into user-visible content ('content_delta', 'content_snapshot') and
/// mechanical/diagnostic types ('lifecycle', 'diagnostic', 'terminal') so SDKs can
/// distinguish what belongs in a chat UI from what is orchestration detail. Forward
/// compatibility: this union closes with an open 'unknown_event' branch so a consumer built
/// against an older revision of this schema does not hard-fail when a newer, additive minor
/// revision introduces a new known type; per contracts/README.md's schema evolution policy,
/// SDKs must treat an unrecognized 'type' as ignore-or-pass-through-for-diagnostics, never
/// as a hard error. Design seam only; no engine or provider implementation exists yet (see
/// docs/architecture/architecture.md).
// MARK: - StreamEvent
public struct StreamEvent: Codable, Sendable {
    /// Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
    /// matching the same guardrail as TelemetryEvent.payload.
    ///
    /// Structurally identical to StreamTerminalOutcome
    /// (contracts/schemas/stream-terminal-outcome.schema.json), duplicated by value here rather
    /// than by $ref, matching this repo's schema convention of no cross-file references. Keep
    /// both shapes in sync; a cross-check test asserts a shared fixture validates against both
    /// schemas.
    ///
    /// Optional event-specific payload for the unrecognized type. It must not contain prompt
    /// payloads or raw secrets.
    public var payload: Payload?
    /// Opaque run identifier this event belongs to, matching StreamRunHandle.runId.
    public var runId: String
    /// Contract schema version used to interpret this event payload.
    public var schemaVersion: SchemaVersion
    /// Zero-based, monotonically increasing event index within this run. The ordering authority;
    /// do not rely on delivery/arrival order.
    ///
    /// Zero-based, monotonically increasing event index within this run. This is always the
    /// highest sequence number for the run: the terminal event.
    public var sequence: Int
    /// Wall-clock event timestamp in Unix epoch milliseconds.
    public var timestamp: Double
    /// User-visible content: an incremental text increment since the previous content_delta or
    /// content_snapshot event. Mirrors ProviderDescriptor.streamingStyle 'tokens'/'chunks'
    /// (packages/inderun-web/src/core/provider.ts) — providers reporting either style normalize
    /// to content_delta.
    ///
    /// User-visible content: the full cumulative text produced so far. Mirrors
    /// ProviderDescriptor.streamingStyle 'snapshots' (packages/inderun-web/src/core/provider.ts)
    /// — providers reporting that style normalize to content_snapshot rather than
    /// content_delta.
    ///
    /// Mechanical/diagnostic: a run lifecycle transition (e.g. provider selection, execution
    /// start). Not user-visible content; not part of the generated text.
    ///
    /// Mechanical/diagnostic: free-form orchestration or provider diagnostic detail. Not
    /// user-visible content.
    ///
    /// Terminal: the last event of the run, carrying the mutually-exclusive
    /// completion/error/cancellation outcome. No further StreamEvent is delivered for this runId
    /// after this event.
    ///
    /// Forward-compatibility catch-all: any event type not among the known constants above.
    /// Exists so a consumer validating against this revision of the schema does not hard-fail
    /// when a future additive revision introduces a new known event type; SDKs must ignore or
    /// pass through such events for diagnostics rather than treating them as an error.
    public var type: String

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case sequence = "sequence"
        case timestamp = "timestamp"
        case type = "type"
    }

    public init(payload: Payload?, runId: String, schemaVersion: SchemaVersion, sequence: Int, timestamp: Double, type: String) {
        self.payload = payload
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: StreamEvent convenience initializers and mutators

public extension StreamEvent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamEvent.self, from: data)
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
        payload: Payload?? = nil,
        runId: String? = nil,
        schemaVersion: SchemaVersion? = nil,
        sequence: Int? = nil,
        timestamp: Double? = nil,
        type: String? = nil
    ) -> StreamEvent {
        return StreamEvent(
            payload: payload ?? self.payload,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            sequence: sequence ?? self.sequence,
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

/// Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
/// matching the same guardrail as TelemetryEvent.payload.
///
/// Optional event-specific payload for the unrecognized type. It must not contain prompt
/// payloads or raw secrets.
// MARK: - Payload
public struct Payload: Codable, Sendable {
    /// The incremental text produced since the previous content event.
    ///
    /// The full cumulative text produced by the run so far.
    public var text: String?
    /// The lifecycle phase reached.
    public var phase: Phase?
    public var finalText: String?
    public var outcome: Outcome?
    public var runId: String?
    public var schemaVersion: SchemaVersion?
    public var telemetry: PayloadTelemetry?
    public var usage: PayloadUsage?
    public var error: PayloadError?
    public var partialText: String?
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case text = "text"
        case phase = "phase"
        case finalText = "finalText"
        case outcome = "outcome"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
        case error = "error"
        case partialText = "partialText"
        case reason = "reason"
    }

    public init(text: String?, phase: Phase?, finalText: String?, outcome: Outcome?, runId: String?, schemaVersion: SchemaVersion?, telemetry: PayloadTelemetry?, usage: PayloadUsage?, error: PayloadError?, partialText: String?, reason: String?) {
        self.text = text
        self.phase = phase
        self.finalText = finalText
        self.outcome = outcome
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.telemetry = telemetry
        self.usage = usage
        self.error = error
        self.partialText = partialText
        self.reason = reason
    }
}

// MARK: Payload convenience initializers and mutators

public extension Payload {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Payload.self, from: data)
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
        text: String?? = nil,
        phase: Phase?? = nil,
        finalText: String?? = nil,
        outcome: Outcome?? = nil,
        runId: String?? = nil,
        schemaVersion: SchemaVersion?? = nil,
        telemetry: PayloadTelemetry?? = nil,
        usage: PayloadUsage?? = nil,
        error: PayloadError?? = nil,
        partialText: String?? = nil,
        reason: String?? = nil
    ) -> Payload {
        return Payload(
            text: text ?? self.text,
            phase: phase ?? self.phase,
            finalText: finalText ?? self.finalText,
            outcome: outcome ?? self.outcome,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            telemetry: telemetry ?? self.telemetry,
            usage: usage ?? self.usage,
            error: error ?? self.error,
            partialText: partialText ?? self.partialText,
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

// MARK: - PayloadError
public struct PayloadError: Codable, Sendable {
    public var details: [String: JSONAny]?
    public var errorClass: ErrorClass
    public var message: String
    public var providerId: String?
    public var retryable: Bool?
    public var retryAfterMs: Int?
    public var schemaVersion: SchemaVersion

    public enum CodingKeys: String, CodingKey {
        case details = "details"
        case errorClass = "errorClass"
        case message = "message"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case schemaVersion = "schemaVersion"
    }

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, providerId: String?, retryable: Bool?, retryAfterMs: Int?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.providerId = providerId
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.schemaVersion = schemaVersion
    }
}

// MARK: PayloadError convenience initializers and mutators

public extension PayloadError {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PayloadError.self, from: data)
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
        schemaVersion: SchemaVersion? = nil
    ) -> PayloadError {
        return PayloadError(
            details: details ?? self.details,
            errorClass: errorClass ?? self.errorClass,
            message: message ?? self.message,
            providerId: providerId ?? self.providerId,
            retryable: retryable ?? self.retryable,
            retryAfterMs: retryAfterMs ?? self.retryAfterMs,
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

public enum Outcome: String, Codable, Sendable {
    case cancelled = "cancelled"
    case completed = "completed"
    case error = "error"
}

/// The lifecycle phase reached.
public enum Phase: String, Codable, Sendable {
    case providerSelected = "provider_selected"
    case started = "started"
}

// MARK: - PayloadTelemetry
public struct PayloadTelemetry: Codable, Sendable {
    public var providerUsed: String
    public var totalMs: Double

    public enum CodingKeys: String, CodingKey {
        case providerUsed = "providerUsed"
        case totalMs = "totalMs"
    }

    public init(providerUsed: String, totalMs: Double) {
        self.providerUsed = providerUsed
        self.totalMs = totalMs
    }
}

// MARK: PayloadTelemetry convenience initializers and mutators

public extension PayloadTelemetry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PayloadTelemetry.self, from: data)
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
        providerUsed: String? = nil,
        totalMs: Double? = nil
    ) -> PayloadTelemetry {
        return PayloadTelemetry(
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

// MARK: - PayloadUsage
public struct PayloadUsage: Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case totalTokens = "totalTokens"
    }

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

// MARK: PayloadUsage convenience initializers and mutators

public extension PayloadUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PayloadUsage.self, from: data)
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
    ) -> PayloadUsage {
        return PayloadUsage(
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

/// How a Mode 2 stream run ended. Completion, error, and cancellation are mutually exclusive
/// terminal outcomes, enforced here as a closed set of three oneOf branches discriminated by
/// 'outcome' (unlike StreamEvent.type, this set is not open-ended: the three-way terminal
/// outcome is a fixed architectural guarantee, not something new outcome kinds get added
/// to). Exactly one StreamTerminalOutcome is produced per run, and no further StreamEvent is
/// delivered after it (see docs/architecture/architecture.md, 'Cancellation And Fallback').
/// This shape is also embedded by value as the payload of the terminal StreamEvent
/// (stream-event.schema.json) so it can additionally be exposed standalone, e.g. as a
/// completion future/promise a stream handle resolves independently of consuming the full
/// event sequence; the two copies must stay structurally identical. Note on
/// additionalProperties: per this repo's forward-compatible convention every branch permits
/// unknown extra fields, so mutual exclusivity is enforced via the required 'outcome'
/// discriminator plus each branch's own required peer field (finalText/error/partialText)
/// being present, not by forbidding a payload from also carrying an unrelated stray field
/// from another branch's vocabulary.
// MARK: - StreamTerminalOutcome
public struct StreamTerminalOutcome: Codable, Sendable {
    /// The full, cumulative text produced by the run. Equivalent in role to
    /// TaskResult.output.text for Mode 1.
    public var finalText: String?
    /// The stream completed normally: every provider-generated event was delivered before this
    /// outcome was produced.
    ///
    /// The stream ended in failure: validation, routing (no eligible provider), or every
    /// attempted provider failing.
    ///
    /// The stream was cancelled. No further StreamEvent is delivered after this outcome, and no
    /// further fallback attempt is made, per the engine's cancellation guarantee.
    public var outcome: Outcome
    /// The stream run this outcome terminates, matching StreamRunHandle.runId and every
    /// StreamEvent.runId for the run.
    public var runId: String
    /// Contract schema version used to interpret this outcome payload.
    public var schemaVersion: SchemaVersion
    /// Required metadata providing an overview of the execution result and performance metrics.
    /// Same shape as TaskResult.telemetry.
    public var telemetry: StreamTerminalOutcomeTelemetry?
    /// Optional metadata regarding the quantity of tokens processed by the provider. Same shape
    /// as TaskResult.usage.
    public var usage: StreamTerminalOutcomeUsage?
    /// The normalized error for this failure. Structurally identical to IndeRunError
    /// (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
    /// $ref, matching this repo's schema convention of no cross-file references. Keep both
    /// shapes in sync; a cross-check test asserts a shared fixture validates against both
    /// schemas.
    public var error: StreamTerminalOutcomeError?
    /// Whatever cumulative text had already been delivered via content_delta/content_snapshot
    /// StreamEvents before the cancellation point. May be empty if cancellation occurred before
    /// any content was produced.
    public var partialText: String?
    /// Optional human-readable reason the run was cancelled (e.g. caller-initiated abort). Not a
    /// machine-taxonomy field; use errorClass on the 'error' outcome branch for failure
    /// classification.
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case finalText = "finalText"
        case outcome = "outcome"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
        case error = "error"
        case partialText = "partialText"
        case reason = "reason"
    }

    public init(finalText: String?, outcome: Outcome, runId: String, schemaVersion: SchemaVersion, telemetry: StreamTerminalOutcomeTelemetry?, usage: StreamTerminalOutcomeUsage?, error: StreamTerminalOutcomeError?, partialText: String?, reason: String?) {
        self.finalText = finalText
        self.outcome = outcome
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.telemetry = telemetry
        self.usage = usage
        self.error = error
        self.partialText = partialText
        self.reason = reason
    }
}

// MARK: StreamTerminalOutcome convenience initializers and mutators

public extension StreamTerminalOutcome {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamTerminalOutcome.self, from: data)
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
        finalText: String?? = nil,
        outcome: Outcome? = nil,
        runId: String? = nil,
        schemaVersion: SchemaVersion? = nil,
        telemetry: StreamTerminalOutcomeTelemetry?? = nil,
        usage: StreamTerminalOutcomeUsage?? = nil,
        error: StreamTerminalOutcomeError?? = nil,
        partialText: String?? = nil,
        reason: String?? = nil
    ) -> StreamTerminalOutcome {
        return StreamTerminalOutcome(
            finalText: finalText ?? self.finalText,
            outcome: outcome ?? self.outcome,
            runId: runId ?? self.runId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            telemetry: telemetry ?? self.telemetry,
            usage: usage ?? self.usage,
            error: error ?? self.error,
            partialText: partialText ?? self.partialText,
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

/// The normalized error for this failure. Structurally identical to IndeRunError
/// (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
/// $ref, matching this repo's schema convention of no cross-file references. Keep both
/// shapes in sync; a cross-check test asserts a shared fixture validates against both
/// schemas.
// MARK: - StreamTerminalOutcomeError
public struct StreamTerminalOutcomeError: Codable, Sendable {
    /// Optional structured diagnostic details. It must not contain raw secrets.
    public var details: [String: JSONAny]?
    /// Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
    /// (request needs something no eligible provider supports), Offline/Unavailable (provider
    /// unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
    /// throttled the request), Timeout (provider exceeded its execution budget), Internal
    /// (unexpected engine-side failure).
    public var errorClass: ErrorClass
    /// Human-readable error message suitable for logs and developer diagnostics.
    public var message: String
    /// Identifier of the provider associated with the failure, if execution reached a provider.
    public var providerId: String?
    /// Whether retrying the same request may succeed.
    public var retryable: Bool?
    /// Optional suggested delay before retrying, in milliseconds.
    public var retryAfterMs: Int?
    /// Contract schema version used to interpret the error payload.
    public var schemaVersion: SchemaVersion

    public enum CodingKeys: String, CodingKey {
        case details = "details"
        case errorClass = "errorClass"
        case message = "message"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case schemaVersion = "schemaVersion"
    }

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, providerId: String?, retryable: Bool?, retryAfterMs: Int?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.providerId = providerId
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.schemaVersion = schemaVersion
    }
}

// MARK: StreamTerminalOutcomeError convenience initializers and mutators

public extension StreamTerminalOutcomeError {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamTerminalOutcomeError.self, from: data)
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
        schemaVersion: SchemaVersion? = nil
    ) -> StreamTerminalOutcomeError {
        return StreamTerminalOutcomeError(
            details: details ?? self.details,
            errorClass: errorClass ?? self.errorClass,
            message: message ?? self.message,
            providerId: providerId ?? self.providerId,
            retryable: retryable ?? self.retryable,
            retryAfterMs: retryAfterMs ?? self.retryAfterMs,
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

/// Required metadata providing an overview of the execution result and performance metrics.
/// Same shape as TaskResult.telemetry.
// MARK: - StreamTerminalOutcomeTelemetry
public struct StreamTerminalOutcomeTelemetry: Codable, Sendable {
    /// The identifier for the specific provider that handled the request (e.g.,
    /// 'openai_compatible_cloud').
    public var providerUsed: String
    /// Measured execution duration in milliseconds, including route selection and result
    /// processing.
    public var totalMs: Double

    public enum CodingKeys: String, CodingKey {
        case providerUsed = "providerUsed"
        case totalMs = "totalMs"
    }

    public init(providerUsed: String, totalMs: Double) {
        self.providerUsed = providerUsed
        self.totalMs = totalMs
    }
}

// MARK: StreamTerminalOutcomeTelemetry convenience initializers and mutators

public extension StreamTerminalOutcomeTelemetry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamTerminalOutcomeTelemetry.self, from: data)
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
        providerUsed: String? = nil,
        totalMs: Double? = nil
    ) -> StreamTerminalOutcomeTelemetry {
        return StreamTerminalOutcomeTelemetry(
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

/// Optional metadata regarding the quantity of tokens processed by the provider. Same shape
/// as TaskResult.usage.
// MARK: - StreamTerminalOutcomeUsage
public struct StreamTerminalOutcomeUsage: Codable, Sendable {
    /// Number of input tokens consumed, as reported by the provider.
    public var inputTokens: Int?
    /// Number of output tokens generated, as reported by the provider.
    public var outputTokens: Int?
    /// Aggregated token count for this request, as reported by the provider.
    public var totalTokens: Int?

    public enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case totalTokens = "totalTokens"
    }

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

// MARK: StreamTerminalOutcomeUsage convenience initializers and mutators

public extension StreamTerminalOutcomeUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StreamTerminalOutcomeUsage.self, from: data)
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
    ) -> StreamTerminalOutcomeUsage {
        return StreamTerminalOutcomeUsage(
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

    public func hash(into hasher: inout Hasher) {
        // No-op
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
