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
//   let providerCapabilitySnapshot = try ProviderCapabilitySnapshot(json)
//   let artifactReadRequest = try ArtifactReadRequest(json)

import Foundation

/// The request payload for a run() or stream() execution. The common envelope
/// (schemaVersion, requestId, task, modelProfile, constraints, preferences, telemetry,
/// authContextRef) is task-agnostic; each task kind owns its payload (ADR 016).
/// text_to_text: at least one of `prompt` (single-turn) or `messages` (multi-turn) must be
/// present — both may be present together, though callers should typically supply just one —
/// and `speech`/`delivery` are forbidden. text_to_speech: `speech` and `delivery` are
/// required and `prompt`, `messages` and `generation` are forbidden.
/// `constraints`/`preferences` steer routing but never select a provider directly.
// MARK: - TaskRequest
public struct TaskRequest: Codable, Sendable {
    /// A unique identifier used to retrieve credentials from a secure local storage. Raw
    /// sensitive keys (API keys, etc.) should NEVER be placed directly in the request payload.
    public var authContextRef: String?
    /// Request-level routing constraints used by the planner.
    public var constraints: TaskRequestConstraints?
    /// How the result of a non-text task must reach the application (ADR 016). Required for
    /// non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
    /// provider never substitutes playback for an artifact or the reverse.
    public var delivery: OutputDeliveryRequest?
    /// Optional configuration for fine-tuning how the AI model generates its response.
    public var generation: Generation?
    /// A list of interaction messages for multi-turn conversation or chat-style execution.
    public var messages: [Message]?
    /// Name of the model profile to route within, as configured on the engine. Absent or 'auto'
    /// means every registered target, ranked by constraints and preferences alone. A profile is
    /// an application-defined, ordered allow-list of targets (provider instances bound to one
    /// model each); raw model or provider identifiers are never accepted here. An unknown
    /// profile name fails request validation.
    public var modelProfile: String?
    /// Soft routing preferences used for deterministic provider ordering.
    public var preferences: TaskRequestPreferences?
    /// A simple, single-turn text prompt used to trigger a response from the AI model.
    public var prompt: String?
    /// Optional identifier for tracking or correlating this specific execution attempt.
    public var requestId: String?
    /// Contract schema version used to interpret the request payload.
    public var schemaVersion: SchemaVersion
    /// The text_to_speech payload. Required for text_to_speech and forbidden for every other
    /// kind.
    public var speech: SpeechInput?
    /// A descriptor specifying the type of work to be performed. The kind selects which payload
    /// the request must carry.
    public var task: TaskRequestTask
    /// Execution preferences for tracking usage and performance metrics.
    public var telemetry: TaskRequestTelemetry?

    public enum CodingKeys: String, CodingKey {
        case authContextRef = "authContextRef"
        case constraints = "constraints"
        case delivery = "delivery"
        case generation = "generation"
        case messages = "messages"
        case modelProfile = "modelProfile"
        case preferences = "preferences"
        case prompt = "prompt"
        case requestId = "requestId"
        case schemaVersion = "schemaVersion"
        case speech = "speech"
        case task = "task"
        case telemetry = "telemetry"
    }

    public init(authContextRef: String?, constraints: TaskRequestConstraints?, delivery: OutputDeliveryRequest?, generation: Generation?, messages: [Message]?, modelProfile: String?, preferences: TaskRequestPreferences?, prompt: String?, requestId: String?, schemaVersion: SchemaVersion, speech: SpeechInput?, task: TaskRequestTask, telemetry: TaskRequestTelemetry?) {
        self.authContextRef = authContextRef
        self.constraints = constraints
        self.delivery = delivery
        self.generation = generation
        self.messages = messages
        self.modelProfile = modelProfile
        self.preferences = preferences
        self.prompt = prompt
        self.requestId = requestId
        self.schemaVersion = schemaVersion
        self.speech = speech
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
        delivery: OutputDeliveryRequest?? = nil,
        generation: Generation?? = nil,
        messages: [Message]?? = nil,
        modelProfile: String?? = nil,
        preferences: TaskRequestPreferences?? = nil,
        prompt: String?? = nil,
        requestId: String?? = nil,
        schemaVersion: SchemaVersion? = nil,
        speech: SpeechInput?? = nil,
        task: TaskRequestTask? = nil,
        telemetry: TaskRequestTelemetry?? = nil
    ) -> TaskRequest {
        return TaskRequest(
            authContextRef: authContextRef ?? self.authContextRef,
            constraints: constraints ?? self.constraints,
            delivery: delivery ?? self.delivery,
            generation: generation ?? self.generation,
            messages: messages ?? self.messages,
            modelProfile: modelProfile ?? self.modelProfile,
            preferences: preferences ?? self.preferences,
            prompt: prompt ?? self.prompt,
            requestId: requestId ?? self.requestId,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            speech: speech ?? self.speech,
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
    public var privacy: Privacy?
    /// Optional timeout budget in milliseconds, passed to the planner and to providers. It
    /// bounds the time until the run commits to a provider -- its first content, its first
    /// possible audible effect, or its artifact handoff -- not the duration of audio it plays.
    /// The engines add no timers of their own.
    public var timeoutMs: Int?

    public enum CodingKeys: String, CodingKey {
        case cloud = "cloud"
        case privacy = "privacy"
        case timeoutMs = "timeoutMs"
    }

    public init(cloud: Cloud?, privacy: Privacy?, timeoutMs: Int?) {
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
        privacy: Privacy?? = nil,
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
public enum Privacy: String, Codable, Sendable {
    case cloudAllowed = "cloud_allowed"
    case cloudRequired = "cloud_required"
    case localPreferred = "local_preferred"
    case localRequired = "local_required"
}

/// How the result of a non-text task must reach the application (ADR 016). Required for
/// non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
/// provider never substitutes playback for an artifact or the reverse.
// MARK: - OutputDeliveryRequest
public struct OutputDeliveryRequest: Codable, Sendable {
    /// Only valid with 'artifact' delivery: the acceptable media types, always a hard
    /// requirement. Absent means the provider chooses and the artifact reports what it produced.
    public var mediaTypes: [String]?
    public var mode: OutputDelivery

    public enum CodingKeys: String, CodingKey {
        case mediaTypes = "mediaTypes"
        case mode = "mode"
    }

    public init(mediaTypes: [String]?, mode: OutputDelivery) {
        self.mediaTypes = mediaTypes
        self.mode = mode
    }
}

// MARK: OutputDeliveryRequest convenience initializers and mutators

public extension OutputDeliveryRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OutputDeliveryRequest.self, from: data)
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
        mediaTypes: [String]?? = nil,
        mode: OutputDelivery? = nil
    ) -> OutputDeliveryRequest {
        return OutputDeliveryRequest(
            mediaTypes: mediaTypes ?? self.mediaTypes,
            mode: mode ?? self.mode
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// How a task's result reaches the application: 'inline' content in the result (text),
/// 'playback' as a managed, audible effect on the device with no retrievable bytes, or
/// 'artifact' as retrievable media.
public enum OutputDelivery: String, Codable, Sendable {
    case artifact = "artifact"
    case inline = "inline"
    case playback = "playback"
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

/// The text_to_speech payload. Required for text_to_speech and forbidden for every other
/// kind.
// MARK: - SpeechInput
public struct SpeechInput: Codable, Sendable {
    /// BCP 47 tag of the language to speak, e.g. 'de-AT'.
    public var locale: String
    /// 'language' (default): the primary language subtag is a hard requirement and the region is
    /// a preference. 'exact': the full tag is a hard requirement.
    public var localeMatch: LocaleMatch?
    /// Plain text to speak. Markup such as SSML is out of scope.
    public var text: String
    /// Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
    /// and is never a reason to fail; a 'required' one takes part in routing and is never
    /// relaxed silently. Carries no provider voice identifier.
    public var voice: SpeechVoice?

    public enum CodingKeys: String, CodingKey {
        case locale = "locale"
        case localeMatch = "localeMatch"
        case text = "text"
        case voice = "voice"
    }

    public init(locale: String, localeMatch: LocaleMatch?, text: String, voice: SpeechVoice?) {
        self.locale = locale
        self.localeMatch = localeMatch
        self.text = text
        self.voice = voice
    }
}

// MARK: SpeechInput convenience initializers and mutators

public extension SpeechInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpeechInput.self, from: data)
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
        locale: String? = nil,
        localeMatch: LocaleMatch?? = nil,
        text: String? = nil,
        voice: SpeechVoice?? = nil
    ) -> SpeechInput {
        return SpeechInput(
            locale: locale ?? self.locale,
            localeMatch: localeMatch ?? self.localeMatch,
            text: text ?? self.text,
            voice: voice ?? self.voice
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// 'language' (default): the primary language subtag is a hard requirement and the region is
/// a preference. 'exact': the full tag is a hard requirement.
///
/// 'exact' requires the full tag; 'language' requires only the primary language subtag and
/// treats the region as a preference.
public enum LocaleMatch: String, Codable, Sendable {
    case exact = "exact"
    case language = "language"
}

/// Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
/// and is never a reason to fail; a 'required' one takes part in routing and is never
/// relaxed silently. Carries no provider voice identifier.
// MARK: - SpeechVoice
public struct SpeechVoice: Codable, Sendable {
    public var gender: VoiceGender?
    /// 'preferred' (default) or 'required'. A required voice must name at least one trait.
    public var requirement: RequirementLevel?

    public enum CodingKeys: String, CodingKey {
        case gender = "gender"
        case requirement = "requirement"
    }

    public init(gender: VoiceGender?, requirement: RequirementLevel?) {
        self.gender = gender
        self.requirement = requirement
    }
}

// MARK: SpeechVoice convenience initializers and mutators

public extension SpeechVoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpeechVoice.self, from: data)
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
        gender: VoiceGender?? = nil,
        requirement: RequirementLevel?? = nil
    ) -> SpeechVoice {
        return SpeechVoice(
            gender: gender ?? self.gender,
            requirement: requirement ?? self.requirement
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Perceived gender of a voice, as the platform reports it.
public enum VoiceGender: String, Codable, Sendable {
    case female = "female"
    case male = "male"
    case neutral = "neutral"
}

/// 'preferred' (default) or 'required'. A required voice must name at least one trait.
///
/// 'required' takes part in routing; 'preferred' does not.
public enum RequirementLevel: String, Codable, Sendable {
    case preferred = "preferred"
    case requirementLevelRequired = "required"
}

/// A descriptor specifying the type of work to be performed. The kind selects which payload
/// the request must carry.
// MARK: - TaskRequestTask
public struct TaskRequestTask: Codable, Sendable {
    /// The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
    /// synthesis from text). A consumer built against an older revision rejects a kind it does
    /// not know through validation.
    public var kind: TaskKind

    public enum CodingKeys: String, CodingKey {
        case kind = "kind"
    }

    public init(kind: TaskKind) {
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
        kind: TaskKind? = nil
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

/// The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
/// synthesis from text). A consumer built against an older revision rejects a kind it does
/// not know through validation.
public enum TaskKind: String, Codable, Sendable {
    case textToSpeech = "text_to_speech"
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

/// The response payload for a completed run() execution, for every task kind; output.type
/// tells the content representation apart (text, managed playback, retrievable artifact). A
/// full execution failure (validation, routing, or every attempted provider failing) is
/// surfaced by run() throwing an IndeRunError instead of returning a TaskResult;
/// finishReason and telemetry.errorClass are reserved for a provider reporting a non-fatal,
/// degraded outcome on an otherwise-successful result (finishReason 'error' is produced by
/// the Android ML Kit GenAI provider; telemetry.errorClass is not currently set by any
/// provider in this codebase).
// MARK: - TaskResult
public struct TaskResult: Codable, Sendable {
    /// How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
    /// 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
    /// otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
    /// Nano reports a finish reason that is neither a natural stop nor the token limit. A full
    /// execution failure is instead surfaced by run() throwing an IndeRunError.
    public var finishReason: FinishReason
    /// The normalized output of the selected provider. See task-output.schema.json.
    public var output: TaskOutput
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
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
        case provenance = "provenance"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
    }

    public init(finishReason: FinishReason, output: TaskOutput, provenance: ExecutionProvenance?, runId: String, schemaVersion: SchemaVersion, telemetry: TaskResultTelemetry, usage: TaskResultUsage?) {
        self.finishReason = finishReason
        self.output = output
        self.provenance = provenance
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
        output: TaskOutput? = nil,
        provenance: ExecutionProvenance?? = nil,
        runId: String? = nil,
        schemaVersion: SchemaVersion? = nil,
        telemetry: TaskResultTelemetry? = nil,
        usage: TaskResultUsage?? = nil
    ) -> TaskResult {
        return TaskResult(
            finishReason: finishReason ?? self.finishReason,
            output: output ?? self.output,
            provenance: provenance ?? self.provenance,
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
/// otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
/// Nano reports a finish reason that is neither a natural stop nor the token limit. A full
/// execution failure is instead surfaced by run() throwing an IndeRunError.
///
/// How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
/// 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
/// otherwise completed run). 'cancelled' is included so this enum stays identical to
/// TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
/// outcome branch. Optional: providers that do not report a finish reason omit it.
public enum FinishReason: String, Codable, Sendable {
    case cancelled = "cancelled"
    case error = "error"
    case length = "length"
    case stop = "stop"
}

/// The normalized output of the selected provider. See task-output.schema.json.
///
/// The normalized output of a run, shared by TaskResult and the completed and cancelled
/// stream terminal outcomes (ADR 016). 'type' describes the content representation, not the
/// task: 'text' carries inline text, 'playback' reports a managed, audible effect that has
/// no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback
/// output is never an artifact, and an artifact output never implies that anything was
/// played.
///
/// The normalized output of the run, the same shape run() returns in TaskResult.output. Set
/// for every non-text run; a text run may set it alongside finalText. See
/// task-output.schema.json.
///
/// What a cancelled non-text run had already produced: a playback run that committed (audio
/// may have been heard) carries a playback output. Absent when nothing was produced, e.g. an
/// artifact run cancelled before its artifact was handed over, whose partial media the
/// engine discards. See task-output.schema.json.
// MARK: - TaskOutput
public struct TaskOutput: Codable, Sendable {
    /// The retrievable media the run produced. Required when type is 'artifact'.
    public var artifact: MediaArtifact?
    /// Completion of managed playback. Required when type is 'playback'. Carries no media.
    public var playback: PlaybackOutput?
    /// The locale and voice traits a text-to-speech run actually used, so an unmet preference is
    /// visible without being an error.
    public var speech: SpeechOutput?
    /// The text the run produced. Required when type is 'text'.
    public var text: String?
    /// The content representation: 'text', 'playback' or 'artifact'.
    public var type: TaskOutputType

    public enum CodingKeys: String, CodingKey {
        case artifact = "artifact"
        case playback = "playback"
        case speech = "speech"
        case text = "text"
        case type = "type"
    }

    public init(artifact: MediaArtifact?, playback: PlaybackOutput?, speech: SpeechOutput?, text: String?, type: TaskOutputType) {
        self.artifact = artifact
        self.playback = playback
        self.speech = speech
        self.text = text
        self.type = type
    }
}

// MARK: TaskOutput convenience initializers and mutators

public extension TaskOutput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TaskOutput.self, from: data)
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
        artifact: MediaArtifact?? = nil,
        playback: PlaybackOutput?? = nil,
        speech: SpeechOutput?? = nil,
        text: String?? = nil,
        type: TaskOutputType? = nil
    ) -> TaskOutput {
        return TaskOutput(
            artifact: artifact ?? self.artifact,
            playback: playback ?? self.playback,
            speech: speech ?? self.speech,
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

/// The retrievable media the run produced. Required when type is 'artifact'.
///
/// A reference to retrievable media a run produced (ADR 017). It carries no bytes and no
/// location: an engine-owned artifact is read through the engine by id, and an
/// application-owned one was written to an application destination. Media-neutral: audio,
/// images and video share this shape and differ only in mediaType.
// MARK: - MediaArtifact
public struct MediaArtifact: Codable, Sendable {
    /// Size of the media in bytes. Always set for an artifact the engine materialized.
    public var byteLength: Int?
    /// Duration of time-based media in milliseconds, where the producer knows it.
    public var durationMs: Double?
    /// Opaque, engine-issued identifier. Never a path, URL or provider identifier.
    public var id: String
    /// How long the engine keeps the bytes. 'until_disposed': until the application disposes the
    /// artifact or the process ends; the artifact outlives the run that produced it.
    public var lifetime: ArtifactLifetime
    /// IANA media type of the bytes, e.g. 'audio/wav'. Encoding parameters ride on the media
    /// type (e.g. 'audio/L16;rate=22050').
    public var mediaType: String
    /// 'engine': the engine holds the bytes and the application reads them by id until it
    /// disposes the artifact. 'application': the bytes were written to the application
    /// destination named by destinationRef and the engine holds nothing.
    public var owner: ArtifactOwner

    public enum CodingKeys: String, CodingKey {
        case byteLength = "byteLength"
        case durationMs = "durationMs"
        case id = "id"
        case lifetime = "lifetime"
        case mediaType = "mediaType"
        case owner = "owner"
    }

    public init(byteLength: Int?, durationMs: Double?, id: String, lifetime: ArtifactLifetime, mediaType: String, owner: ArtifactOwner) {
        self.byteLength = byteLength
        self.durationMs = durationMs
        self.id = id
        self.lifetime = lifetime
        self.mediaType = mediaType
        self.owner = owner
    }
}

// MARK: MediaArtifact convenience initializers and mutators

public extension MediaArtifact {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MediaArtifact.self, from: data)
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
        byteLength: Int?? = nil,
        durationMs: Double?? = nil,
        id: String? = nil,
        lifetime: ArtifactLifetime? = nil,
        mediaType: String? = nil,
        owner: ArtifactOwner? = nil
    ) -> MediaArtifact {
        return MediaArtifact(
            byteLength: byteLength ?? self.byteLength,
            durationMs: durationMs ?? self.durationMs,
            id: id ?? self.id,
            lifetime: lifetime ?? self.lifetime,
            mediaType: mediaType ?? self.mediaType,
            owner: owner ?? self.owner
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// How long the engine keeps the bytes. 'until_disposed': until the application disposes the
/// artifact or the process ends; the artifact outlives the run that produced it.
public enum ArtifactLifetime: String, Codable, Sendable {
    case untilDisposed = "until_disposed"
}

/// 'engine': the engine holds the bytes and the application reads them by id until it
/// disposes the artifact. 'application': the bytes were written to the application
/// destination named by destinationRef and the engine holds nothing.
public enum ArtifactOwner: String, Codable, Sendable {
    case application = "application"
    case engine = "engine"
}

/// Completion of managed playback. Required when type is 'playback'. Carries no media.
// MARK: - PlaybackOutput
public struct PlaybackOutput: Codable, Sendable {
    /// How long audible playback lasted, in milliseconds. For a cancelled run, how long it
    /// played before it was stopped.
    public var durationMs: Double?

    public enum CodingKeys: String, CodingKey {
        case durationMs = "durationMs"
    }

    public init(durationMs: Double?) {
        self.durationMs = durationMs
    }
}

// MARK: PlaybackOutput convenience initializers and mutators

public extension PlaybackOutput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PlaybackOutput.self, from: data)
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
        durationMs: Double?? = nil
    ) -> PlaybackOutput {
        return PlaybackOutput(
            durationMs: durationMs ?? self.durationMs
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The locale and voice traits a text-to-speech run actually used, so an unmet preference is
/// visible without being an error.
// MARK: - SpeechOutput
public struct SpeechOutput: Codable, Sendable {
    /// BCP 47 tag of the locale that was spoken.
    public var locale: String
    /// Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
    public var voice: SpeechOutputVoice?

    public enum CodingKeys: String, CodingKey {
        case locale = "locale"
        case voice = "voice"
    }

    public init(locale: String, voice: SpeechOutputVoice?) {
        self.locale = locale
        self.voice = voice
    }
}

// MARK: SpeechOutput convenience initializers and mutators

public extension SpeechOutput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpeechOutput.self, from: data)
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
        locale: String? = nil,
        voice: SpeechOutputVoice?? = nil
    ) -> SpeechOutput {
        return SpeechOutput(
            locale: locale ?? self.locale,
            voice: voice ?? self.voice
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
// MARK: - SpeechOutputVoice
public struct SpeechOutputVoice: Codable, Sendable {
    public var gender: VoiceGender?

    public enum CodingKeys: String, CodingKey {
        case gender = "gender"
    }

    public init(gender: VoiceGender?) {
        self.gender = gender
    }
}

// MARK: SpeechOutputVoice convenience initializers and mutators

public extension SpeechOutputVoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpeechOutputVoice.self, from: data)
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
        gender: VoiceGender?? = nil
    ) -> SpeechOutputVoice {
        return SpeechOutputVoice(
            gender: gender ?? self.gender
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The content representation: 'text', 'playback' or 'artifact'.
public enum TaskOutputType: String, Codable, Sendable {
    case artifact = "artifact"
    case playback = "playback"
    case text = "text"
}

/// Normalized execution provenance: which target ran, its declared locality, the configured
/// and reported model, and how fallback and routing played out. See
/// execution-provenance.schema.json.
///
/// Provider-neutral record of how an execution was carried out: the target the outcome is
/// attributed to, its declared locality, the configured and provider-reported model, every
/// attempt, and why other candidates were rejected. Carried on TaskResult, on every
/// StreamTerminalOutcome branch, and on IndeRunError. It reports what the engine observed
/// and what providers declared or reported; it never infers a model or locality a provider
/// did not state, and it never contains request content, credentials, or provider payloads.
// MARK: - ExecutionProvenance
public struct ExecutionProvenance: Codable, Sendable {
    /// How many providers were attempted. 0 when the request failed validation or routing, or
    /// was cancelled before any attempt started.
    public var attemptCount: Int
    /// Every attempted provider, in attempt order, with how its attempt ended.
    public var attempts: [ExecutionProvenanceAttempt]
    /// The model providerId is bound to, as its descriptor declares it. Absent when the provider
    /// cannot name its model or no provider is attributed.
    public var configuredModel: String?
    /// Whether more than one provider was attempted (attemptCount > 1).
    public var fallbackOccurred: Bool
    /// Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
    /// 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
    /// providerId is absent.
    public var locality: Locality
    /// The model profile the request routed within; 'auto' when the request named none.
    public var modelProfile: String
    /// The target the outcome is attributed to: the provider that produced the result, the
    /// provider a stream had committed to when it ended, or the provider that was running when
    /// it was cancelled. Absent when no provider was reached or when every attempted provider
    /// failed before one was committed to.
    public var providerId: String?
    /// The model identifier the provider reported in its own response. Absent means the provider
    /// did not report one; it is never inferred from configuration.
    public var reportedModel: String?
    /// Providers the route planner rejected before any attempt, with the normalized RoutePlan
    /// reason codes. Codes only: no provider-supplied messages.
    public var routeRejections: [ExecutionProvenanceRouteRejection]
    /// Contract schema version used to interpret this provenance record.
    public var schemaVersion: SchemaVersion

    public enum CodingKeys: String, CodingKey {
        case attemptCount = "attemptCount"
        case attempts = "attempts"
        case configuredModel = "configuredModel"
        case fallbackOccurred = "fallbackOccurred"
        case locality = "locality"
        case modelProfile = "modelProfile"
        case providerId = "providerId"
        case reportedModel = "reportedModel"
        case routeRejections = "routeRejections"
        case schemaVersion = "schemaVersion"
    }

    public init(attemptCount: Int, attempts: [ExecutionProvenanceAttempt], configuredModel: String?, fallbackOccurred: Bool, locality: Locality, modelProfile: String, providerId: String?, reportedModel: String?, routeRejections: [ExecutionProvenanceRouteRejection], schemaVersion: SchemaVersion) {
        self.attemptCount = attemptCount
        self.attempts = attempts
        self.configuredModel = configuredModel
        self.fallbackOccurred = fallbackOccurred
        self.locality = locality
        self.modelProfile = modelProfile
        self.providerId = providerId
        self.reportedModel = reportedModel
        self.routeRejections = routeRejections
        self.schemaVersion = schemaVersion
    }
}

// MARK: ExecutionProvenance convenience initializers and mutators

public extension ExecutionProvenance {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ExecutionProvenance.self, from: data)
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
        attemptCount: Int? = nil,
        attempts: [ExecutionProvenanceAttempt]? = nil,
        configuredModel: String?? = nil,
        fallbackOccurred: Bool? = nil,
        locality: Locality? = nil,
        modelProfile: String? = nil,
        providerId: String?? = nil,
        reportedModel: String?? = nil,
        routeRejections: [ExecutionProvenanceRouteRejection]? = nil,
        schemaVersion: SchemaVersion? = nil
    ) -> ExecutionProvenance {
        return ExecutionProvenance(
            attemptCount: attemptCount ?? self.attemptCount,
            attempts: attempts ?? self.attempts,
            configuredModel: configuredModel ?? self.configuredModel,
            fallbackOccurred: fallbackOccurred ?? self.fallbackOccurred,
            locality: locality ?? self.locality,
            modelProfile: modelProfile ?? self.modelProfile,
            providerId: providerId ?? self.providerId,
            reportedModel: reportedModel ?? self.reportedModel,
            routeRejections: routeRejections ?? self.routeRejections,
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

// MARK: - ExecutionProvenanceAttempt
public struct ExecutionProvenanceAttempt: Codable, Sendable {
    /// Whether the run committed to this provider during the attempt: its first content was
    /// delivered, it signalled the first possible audible effect, or it handed over an artifact.
    /// After commit a failure ends the run instead of falling back. Absent means the attempt did
    /// not commit.
    public var committed: Bool?
    /// Normalized error class of a failed attempt.
    public var errorClass: ErrorClass?
    /// 'succeeded' (produced the result or was committed to and completed), 'failed', or
    /// 'cancelled'.
    public var outcome: AttemptOutcome
    public var providerId: String

    public enum CodingKeys: String, CodingKey {
        case committed = "committed"
        case errorClass = "errorClass"
        case outcome = "outcome"
        case providerId = "providerId"
    }

    public init(committed: Bool?, errorClass: ErrorClass?, outcome: AttemptOutcome, providerId: String) {
        self.committed = committed
        self.errorClass = errorClass
        self.outcome = outcome
        self.providerId = providerId
    }
}

// MARK: ExecutionProvenanceAttempt convenience initializers and mutators

public extension ExecutionProvenanceAttempt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ExecutionProvenanceAttempt.self, from: data)
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
        committed: Bool?? = nil,
        errorClass: ErrorClass?? = nil,
        outcome: AttemptOutcome? = nil,
        providerId: String? = nil
    ) -> ExecutionProvenanceAttempt {
        return ExecutionProvenanceAttempt(
            committed: committed ?? self.committed,
            errorClass: errorClass ?? self.errorClass,
            outcome: outcome ?? self.outcome,
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

/// Normalized error class of a failed attempt.
///
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

/// 'succeeded' (produced the result or was committed to and completed), 'failed', or
/// 'cancelled'.
public enum AttemptOutcome: String, Codable, Sendable {
    case cancelled = "cancelled"
    case failed = "failed"
    case succeeded = "succeeded"
}

/// Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
/// 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
/// providerId is absent.
public enum Locality: String, Codable, Sendable {
    case cloud = "cloud"
    case edge = "edge"
    case onDevice = "on_device"
    case unknown = "unknown"
}

// MARK: - ExecutionProvenanceRouteRejection
public struct ExecutionProvenanceRouteRejection: Codable, Sendable {
    public var codes: [Code]
    public var providerId: String

    public enum CodingKeys: String, CodingKey {
        case codes = "codes"
        case providerId = "providerId"
    }

    public init(codes: [Code], providerId: String) {
        self.codes = codes
        self.providerId = providerId
    }
}

// MARK: ExecutionProvenanceRouteRejection convenience initializers and mutators

public extension ExecutionProvenanceRouteRejection {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ExecutionProvenanceRouteRejection.self, from: data)
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
        codes: [Code]? = nil,
        providerId: String? = nil
    ) -> ExecutionProvenanceRouteRejection {
        return ExecutionProvenanceRouteRejection(
            codes: codes ?? self.codes,
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

/// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
/// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
/// but the dynamic capability snapshot reports it cannot stream in the current host
/// environment. 'not_in_model_profile' means the request named a model profile that does not
/// list this provider. 'input_not_supported', 'output_delivery_not_supported',
/// 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
/// provider's task capability lacks an input kind, output delivery, media type, locale or
/// voice the request requires.
public enum Code: String, Codable, Sendable {
    case capabilityUnavailable = "capability_unavailable"
    case cloudConstraint = "cloud_constraint"
    case inputNotSupported = "input_not_supported"
    case localeNotSupported = "locale_not_supported"
    case notInModelProfile = "not_in_model_profile"
    case offline = "offline"
    case outputDeliveryNotSupported = "output_delivery_not_supported"
    case outputFormatNotSupported = "output_format_not_supported"
    case privacyConstraint = "privacy_constraint"
    case runNotSupported = "run_not_supported"
    case streamingNotSupported = "streaming_not_supported"
    case streamingUnavailable = "streaming_unavailable"
    case taskNotSupported = "task_not_supported"
    case voiceNotAvailable = "voice_not_available"
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
    /// The model identifier the provider reported in its own response, set by the provider when
    /// its backend reports one. The engine carries it into provenance.reportedModel; it is never
    /// inferred from configuration.
    public var reportedModel: String?
    /// Measured execution duration in milliseconds, including route selection and result
    /// processing.
    public var totalMs: Double

    public enum CodingKeys: String, CodingKey {
        case errorClass = "errorClass"
        case providerUsed = "providerUsed"
        case reportedModel = "reportedModel"
        case totalMs = "totalMs"
    }

    public init(errorClass: ErrorClass?, providerUsed: String, reportedModel: String?, totalMs: Double) {
        self.errorClass = errorClass
        self.providerUsed = providerUsed
        self.reportedModel = reportedModel
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
        reportedModel: String?? = nil,
        totalMs: Double? = nil
    ) -> TaskResultTelemetry {
        return TaskResultTelemetry(
            errorClass: errorClass ?? self.errorClass,
            providerUsed: providerUsed ?? self.providerUsed,
            reportedModel: reportedModel ?? self.reportedModel,
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
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
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
        case provenance = "provenance"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
    }

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, provenance: ExecutionProvenance?, providerId: String?, retryable: Bool?, retryAfterMs: Int?, runId: String?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.provenance = provenance
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
        provenance: ExecutionProvenance?? = nil,
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
            provenance: provenance ?? self.provenance,
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
    case streamAttemptFailed = "stream_attempt_failed"
    case streamAttemptStarted = "stream_attempt_started"
    case streamAttemptSucceeded = "stream_attempt_succeeded"
    case streamCancelled = "stream_cancelled"
    case streamCompleted = "stream_completed"
    case streamFailed = "stream_failed"
}

/// Pure data input contract for deterministic shared-core route planning.
// MARK: - RoutePlannerInput
public struct RoutePlannerInput: Codable, Sendable {
    /// Hard routing constraints evaluated before provider selection.
    public var constraints: RoutePlannerInputConstraints
    /// Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
    /// produced before this field existed keep their exact Mode-1 semantics. The mode filters
    /// eligible providers; it never changes candidate ordering.
    public var interactionMode: InteractionMode?
    /// The resolved model profile the request routes within. Absent means the built-in 'auto'
    /// profile: no allow-list, and ordering by placement and preference alone. When present,
    /// providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
    /// position in targetIds ranks the survivors after placement and before preferences. Ids
    /// that name no registered provider are ignored.
    public var modelProfile: ModelProfile?
    /// Soft route ordering preferences applied after hard filtering.
    public var preferences: RoutePlannerInputPreferences
    /// Static descriptors plus dynamic capability checks for planning. Both shapes are the
    /// provider schemas themselves, shared by $ref, so the planner reads exactly what
    /// checkCapabilities() reports.
    public var providers: [Provider]
    /// Task descriptor for provider task matching: the kind plus the requirements routing can
    /// check against declared capabilities. Absent requirement fields are never checked, so a
    /// text request carries the kind alone.
    public var task: RoutePlannerInputTask

    public enum CodingKeys: String, CodingKey {
        case constraints = "constraints"
        case interactionMode = "interactionMode"
        case modelProfile = "modelProfile"
        case preferences = "preferences"
        case providers = "providers"
        case task = "task"
    }

    public init(constraints: RoutePlannerInputConstraints, interactionMode: InteractionMode?, modelProfile: ModelProfile?, preferences: RoutePlannerInputPreferences, providers: [Provider], task: RoutePlannerInputTask) {
        self.constraints = constraints
        self.interactionMode = interactionMode
        self.modelProfile = modelProfile
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
        interactionMode: InteractionMode?? = nil,
        modelProfile: ModelProfile?? = nil,
        preferences: RoutePlannerInputPreferences? = nil,
        providers: [Provider]? = nil,
        task: RoutePlannerInputTask? = nil
    ) -> RoutePlannerInput {
        return RoutePlannerInput(
            constraints: constraints ?? self.constraints,
            interactionMode: interactionMode ?? self.interactionMode,
            modelProfile: modelProfile ?? self.modelProfile,
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
    public var privacy: Privacy?

    public enum CodingKeys: String, CodingKey {
        case cloud = "cloud"
        case networkOnline = "networkOnline"
        case privacy = "privacy"
    }

    public init(cloud: Cloud?, networkOnline: Bool?, privacy: Privacy?) {
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
        privacy: Privacy?? = nil
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

/// Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
/// produced before this field existed keep their exact Mode-1 semantics. The mode filters
/// eligible providers; it never changes candidate ordering.
public enum InteractionMode: String, Codable, Sendable {
    case run = "run"
    case stream = "stream"
}

/// The resolved model profile the request routes within. Absent means the built-in 'auto'
/// profile: no allow-list, and ordering by placement and preference alone. When present,
/// providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
/// position in targetIds ranks the survivors after placement and before preferences. Ids
/// that name no registered provider are ignored.
// MARK: - ModelProfile
public struct ModelProfile: Codable, Sendable {
    /// Profile name, carried for explanations.
    public var name: String
    /// Provider ids in profile order.
    public var targetIds: [String]

    public enum CodingKeys: String, CodingKey {
        case name = "name"
        case targetIds = "targetIds"
    }

    public init(name: String, targetIds: [String]) {
        self.name = name
        self.targetIds = targetIds
    }
}

// MARK: ModelProfile convenience initializers and mutators

public extension ModelProfile {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ModelProfile.self, from: data)
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
        name: String? = nil,
        targetIds: [String]? = nil
    ) -> ModelProfile {
        return ModelProfile(
            name: name ?? self.name,
            targetIds: targetIds ?? self.targetIds
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
    /// The provider's live capability check, already folded by the engine (for example,
    /// streamingAvailable is false when the provider declares streaming but does not implement
    /// it).
    public var capabilities: ProviderDynamicCapabilities
    /// The provider's static capability declaration.
    public var descriptor: ProviderDescriptor

    public enum CodingKeys: String, CodingKey {
        case capabilities = "capabilities"
        case descriptor = "descriptor"
    }

    public init(capabilities: ProviderDynamicCapabilities, descriptor: ProviderDescriptor) {
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
        capabilities: ProviderDynamicCapabilities? = nil,
        descriptor: ProviderDescriptor? = nil
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

/// The provider's live capability check, already folded by the engine (for example,
/// streamingAvailable is false when the provider declares streaming but does not implement
/// it).
///
/// A provider's live capability check, evaluated on the current host when routing or when
/// checkCapabilities() is called. Unlike the descriptor it can change between calls.
///
/// The provider's live capability check at the time of the call.
// MARK: - ProviderDynamicCapabilities
public struct ProviderDynamicCapabilities: Codable, Sendable {
    /// Whether the provider is available and functional on this host right now.
    public var available: Bool
    /// Whether cancellation is honored on this host right now. Absent inherits the static
    /// descriptor.cancel value: any value other than 'none' means available. Never null.
    public var cancellationAvailable: Bool?
    /// Why the provider is unavailable, when available is false.
    public var reason: String?
    /// Whether the provider can stream (Mode 2) on this host right now. Absent inherits the
    /// static descriptor.supports.streaming value; only set it when the host takes streaming
    /// away from a provider that otherwise declares it. Never null.
    public var streamingAvailable: Bool?
    /// Why streaming is unavailable, when streamingAvailable is false. Absent lets the route
    /// planner synthesize a default message.
    public var streamingUnavailableReason: String?
    /// Per-task overrides of the provider-level check, for tasks whose availability differs on
    /// this host, e.g. a voice that is not installed. Every field of an entry is optional and
    /// absent inherits the provider-level value; a false at either level wins.
    public var taskCapabilities: [ProviderTaskAvailability]?

    public enum CodingKeys: String, CodingKey {
        case available = "available"
        case cancellationAvailable = "cancellationAvailable"
        case reason = "reason"
        case streamingAvailable = "streamingAvailable"
        case streamingUnavailableReason = "streamingUnavailableReason"
        case taskCapabilities = "taskCapabilities"
    }

    public init(available: Bool, cancellationAvailable: Bool?, reason: String?, streamingAvailable: Bool?, streamingUnavailableReason: String?, taskCapabilities: [ProviderTaskAvailability]?) {
        self.available = available
        self.cancellationAvailable = cancellationAvailable
        self.reason = reason
        self.streamingAvailable = streamingAvailable
        self.streamingUnavailableReason = streamingUnavailableReason
        self.taskCapabilities = taskCapabilities
    }
}

// MARK: ProviderDynamicCapabilities convenience initializers and mutators

public extension ProviderDynamicCapabilities {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderDynamicCapabilities.self, from: data)
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
        cancellationAvailable: Bool?? = nil,
        reason: String?? = nil,
        streamingAvailable: Bool?? = nil,
        streamingUnavailableReason: String?? = nil,
        taskCapabilities: [ProviderTaskAvailability]?? = nil
    ) -> ProviderDynamicCapabilities {
        return ProviderDynamicCapabilities(
            available: available ?? self.available,
            cancellationAvailable: cancellationAvailable ?? self.cancellationAvailable,
            reason: reason ?? self.reason,
            streamingAvailable: streamingAvailable ?? self.streamingAvailable,
            streamingUnavailableReason: streamingUnavailableReason ?? self.streamingUnavailableReason,
            taskCapabilities: taskCapabilities ?? self.taskCapabilities
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The live check for one task kind.
// MARK: - ProviderTaskAvailability
public struct ProviderTaskAvailability: Codable, Sendable {
    /// Whether the task can run on this host right now. Absent inherits the provider-level
    /// available. Never null.
    public var available: Bool?
    /// Whether cancellation is honored for this task right now. Absent inherits. Never null.
    public var cancellationAvailable: Bool?
    /// The task kind this entry describes.
    public var kind: String
    /// BCP 47 locales available for this task right now. Absent means the provider cannot
    /// enumerate them.
    public var locales: [String]?
    /// Why the task is unavailable, when available is false.
    public var reason: String?
    /// Whether the task can stream on this host right now. Absent inherits. Never null.
    public var streamingAvailable: Bool?
    /// Why streaming is unavailable for this task, when streamingAvailable is false.
    public var streamingUnavailableReason: String?
    /// Voices available for this task right now. Absent means the provider cannot enumerate
    /// them; a request that requires a voice then never routes to it.
    public var voices: [ProviderVoice]?

    public enum CodingKeys: String, CodingKey {
        case available = "available"
        case cancellationAvailable = "cancellationAvailable"
        case kind = "kind"
        case locales = "locales"
        case reason = "reason"
        case streamingAvailable = "streamingAvailable"
        case streamingUnavailableReason = "streamingUnavailableReason"
        case voices = "voices"
    }

    public init(available: Bool?, cancellationAvailable: Bool?, kind: String, locales: [String]?, reason: String?, streamingAvailable: Bool?, streamingUnavailableReason: String?, voices: [ProviderVoice]?) {
        self.available = available
        self.cancellationAvailable = cancellationAvailable
        self.kind = kind
        self.locales = locales
        self.reason = reason
        self.streamingAvailable = streamingAvailable
        self.streamingUnavailableReason = streamingUnavailableReason
        self.voices = voices
    }
}

// MARK: ProviderTaskAvailability convenience initializers and mutators

public extension ProviderTaskAvailability {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderTaskAvailability.self, from: data)
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
        available: Bool?? = nil,
        cancellationAvailable: Bool?? = nil,
        kind: String? = nil,
        locales: [String]?? = nil,
        reason: String?? = nil,
        streamingAvailable: Bool?? = nil,
        streamingUnavailableReason: String?? = nil,
        voices: [ProviderVoice]?? = nil
    ) -> ProviderTaskAvailability {
        return ProviderTaskAvailability(
            available: available ?? self.available,
            cancellationAvailable: cancellationAvailable ?? self.cancellationAvailable,
            kind: kind ?? self.kind,
            locales: locales ?? self.locales,
            reason: reason ?? self.reason,
            streamingAvailable: streamingAvailable ?? self.streamingAvailable,
            streamingUnavailableReason: streamingUnavailableReason ?? self.streamingUnavailableReason,
            voices: voices ?? self.voices
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Provider-neutral traits of one available voice. Carries no provider voice identifier.
///
/// The voice this candidate must use if it is attempted, chosen by the planner from the
/// provider's dynamic voice inventory. It is the best voice that satisfies the request's
/// locale, required voice traits and privacy — under local-required privacy always one that
/// keeps data on the device — ranked by preferred gender, then exact locale region, then
/// on-device before network. The adapter must use a voice with exactly these traits. Absent
/// when the request names no locale or voice, or the provider does not list its voices; the
/// adapter then chooses itself under the same rules.
// MARK: - ProviderVoice
public struct ProviderVoice: Codable, Sendable {
    public var gender: VoiceGender?
    /// BCP 47 locale the voice speaks.
    public var locale: String
    /// Whether using the voice sends data off the device. Absent inherits the task's privacy
    /// posture.
    public var networkRequired: Bool?

    public enum CodingKeys: String, CodingKey {
        case gender = "gender"
        case locale = "locale"
        case networkRequired = "networkRequired"
    }

    public init(gender: VoiceGender?, locale: String, networkRequired: Bool?) {
        self.gender = gender
        self.locale = locale
        self.networkRequired = networkRequired
    }
}

// MARK: ProviderVoice convenience initializers and mutators

public extension ProviderVoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderVoice.self, from: data)
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
        gender: VoiceGender?? = nil,
        locale: String? = nil,
        networkRequired: Bool?? = nil
    ) -> ProviderVoice {
        return ProviderVoice(
            gender: gender ?? self.gender,
            locale: locale ?? self.locale,
            networkRequired: networkRequired ?? self.networkRequired
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The provider's static capability declaration.
///
/// A provider's static capability declaration: identity, placement, transport, supported
/// interaction modes and tasks, cancellation guarantee, resource limits and privacy posture.
/// It does not change while the provider is registered. The route planner,
/// checkCapabilities() and execution provenance all read this one shape.
// MARK: - ProviderDescriptor
public struct ProviderDescriptor: Codable, Sendable {
    /// Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
    /// reading locally while remote work may continue, 'none' means cancellation is unsupported.
    /// Independently of this value, the engine delivers no event after a cancel.
    public var cancel: CancelSemantics
    /// Unique identifier of the provider instance (a target), e.g. 'apple_foundation_models' or
    /// 'openai_compatible_cloud:gpt-5-mini'. Model profiles list targets by this id.
    public var id: String
    /// Optional input and output resource limits.
    public var limits: ProviderLimits?
    /// The model this provider instance is bound to, when it can name one. Cloud providers
    /// report the model id they send; platform-managed models report an opaque platform alias
    /// rather than a guessed weight name. Absent means the provider cannot name its model.
    public var model: String?
    /// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
    /// or edge provider is treated as keeping data on the device and a cloud provider as sending
    /// it off.
    public var privacy: ProviderPrivacy?
    /// How a streaming provider delivers incremental output: individual tokens, larger chunks,
    /// or whole snapshots. Absent for providers that do not stream.
    public var streamingStyle: StreamingStyle?
    /// Interaction modes and features the provider statically declares.
    public var supports: ProviderSupports
    /// What the provider can do for each task: accepted inputs, interaction modes, output
    /// deliveries and formats, cancellation, locales and privacy. When present it is
    /// authoritative for routing and must list every task the provider serves. When absent (a
    /// legacy descriptor), routing infers exactly one entry — 'text_to_text' with text input,
    /// inline output, run/stream from supports and cancel from cancel — if tasks contains
    /// 'text_to_text', and nothing for any other task: a legacy descriptor is never treated as
    /// capable of a non-text task.
    public var taskCapabilities: [ProviderTaskCapability]?
    /// Task kinds the provider supports, e.g. 'text_to_text'. When taskCapabilities is present
    /// it must describe the same kinds and is what routing reads; without it, routing infers
    /// capabilities for 'text_to_text' alone (see taskCapabilities).
    public var tasks: [String]
    /// How the engine reaches the provider: in-process runtime, operating-system service,
    /// buffered HTTP, server-sent events, or a realtime connection.
    public var transport: ProviderTransport
    /// Execution placement: 'local' (on the device), 'edge', or 'cloud'.
    public var type: ProviderType

    public enum CodingKeys: String, CodingKey {
        case cancel = "cancel"
        case id = "id"
        case limits = "limits"
        case model = "model"
        case privacy = "privacy"
        case streamingStyle = "streamingStyle"
        case supports = "supports"
        case taskCapabilities = "taskCapabilities"
        case tasks = "tasks"
        case transport = "transport"
        case type = "type"
    }

    public init(cancel: CancelSemantics, id: String, limits: ProviderLimits?, model: String?, privacy: ProviderPrivacy?, streamingStyle: StreamingStyle?, supports: ProviderSupports, taskCapabilities: [ProviderTaskCapability]?, tasks: [String], transport: ProviderTransport, type: ProviderType) {
        self.cancel = cancel
        self.id = id
        self.limits = limits
        self.model = model
        self.privacy = privacy
        self.streamingStyle = streamingStyle
        self.supports = supports
        self.taskCapabilities = taskCapabilities
        self.tasks = tasks
        self.transport = transport
        self.type = type
    }
}

// MARK: ProviderDescriptor convenience initializers and mutators

public extension ProviderDescriptor {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderDescriptor.self, from: data)
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
        cancel: CancelSemantics? = nil,
        id: String? = nil,
        limits: ProviderLimits?? = nil,
        model: String?? = nil,
        privacy: ProviderPrivacy?? = nil,
        streamingStyle: StreamingStyle?? = nil,
        supports: ProviderSupports? = nil,
        taskCapabilities: [ProviderTaskCapability]?? = nil,
        tasks: [String]? = nil,
        transport: ProviderTransport? = nil,
        type: ProviderType? = nil
    ) -> ProviderDescriptor {
        return ProviderDescriptor(
            cancel: cancel ?? self.cancel,
            id: id ?? self.id,
            limits: limits ?? self.limits,
            model: model ?? self.model,
            privacy: privacy ?? self.privacy,
            streamingStyle: streamingStyle ?? self.streamingStyle,
            supports: supports ?? self.supports,
            taskCapabilities: taskCapabilities ?? self.taskCapabilities,
            tasks: tasks ?? self.tasks,
            transport: transport ?? self.transport,
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

/// Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
/// reading locally while remote work may continue, 'none' means cancellation is unsupported.
/// Independently of this value, the engine delivers no event after a cancel.
///
/// Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
/// when stopping playback is immediate but a synthesis request cannot be aborted.
public enum CancelSemantics: String, Codable, Sendable {
    case hard = "hard"
    case none = "none"
    case soft = "soft"
}

/// Optional input and output resource limits.
// MARK: - ProviderLimits
public struct ProviderLimits: Codable, Sendable {
    /// Longest accepted or produced audio, in seconds.
    public var maxAudioSeconds: Int?
    /// Largest accepted image, in bytes.
    public var maxImageBytes: Int?
    /// Largest accepted input, in tokens.
    public var maxInputTokens: Int?
    /// Largest output the provider produces, in tokens.
    public var maxOutputTokens: Int?

    public enum CodingKeys: String, CodingKey {
        case maxAudioSeconds = "maxAudioSeconds"
        case maxImageBytes = "maxImageBytes"
        case maxInputTokens = "maxInputTokens"
        case maxOutputTokens = "maxOutputTokens"
    }

    public init(maxAudioSeconds: Int?, maxImageBytes: Int?, maxInputTokens: Int?, maxOutputTokens: Int?) {
        self.maxAudioSeconds = maxAudioSeconds
        self.maxImageBytes = maxImageBytes
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
    }
}

// MARK: ProviderLimits convenience initializers and mutators

public extension ProviderLimits {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderLimits.self, from: data)
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
        maxAudioSeconds: Int?? = nil,
        maxImageBytes: Int?? = nil,
        maxInputTokens: Int?? = nil,
        maxOutputTokens: Int?? = nil
    ) -> ProviderLimits {
        return ProviderLimits(
            maxAudioSeconds: maxAudioSeconds ?? self.maxAudioSeconds,
            maxImageBytes: maxImageBytes ?? self.maxImageBytes,
            maxInputTokens: maxInputTokens ?? self.maxInputTokens,
            maxOutputTokens: maxOutputTokens ?? self.maxOutputTokens
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
/// or edge provider is treated as keeping data on the device and a cloud provider as sending
/// it off.
///
/// Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
/// provider whose speech synthesis uses a network service. Absent inherits
/// descriptor.privacy.
// MARK: - ProviderPrivacy
public struct ProviderPrivacy: Codable, Sendable {
    /// Whether request content leaves the device.
    public var dataLeavesDevice: Bool
    /// Geographic regions where a cloud provider processes data.
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

// MARK: ProviderPrivacy convenience initializers and mutators

public extension ProviderPrivacy {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderPrivacy.self, from: data)
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
    ) -> ProviderPrivacy {
        return ProviderPrivacy(
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

/// How a streaming provider delivers incremental output: individual tokens, larger chunks,
/// or whole snapshots. Absent for providers that do not stream.
public enum StreamingStyle: String, Codable, Sendable {
    case chunks = "chunks"
    case snapshots = "snapshots"
    case tokens = "tokens"
}

/// Interaction modes and features the provider statically declares.
// MARK: - ProviderSupports
public struct ProviderSupports: Codable, Sendable {
    /// Whether the provider accepts non-text inputs such as images or audio.
    public var multimodal: Bool
    /// Whether the provider supports Mode 3 realtime sessions. Reserved; no engine implements
    /// Mode 3 yet.
    public var realtime: Bool
    /// Whether the provider emits reasoning events alongside content.
    public var reasoningEvents: Bool
    /// Whether the provider supports Mode 1 run (request/response).
    public var run: Bool
    /// Whether the provider supports Mode 2 stream. A provider that declares it must also
    /// implement the streaming adapter; the engines report it as unavailable otherwise.
    public var streaming: Bool
    /// Whether the provider supports structured output constrained by a JSON schema.
    public var structuredOutput: Bool
    /// Whether the provider supports tool calling.
    public var tools: Bool

    public enum CodingKeys: String, CodingKey {
        case multimodal = "multimodal"
        case realtime = "realtime"
        case reasoningEvents = "reasoningEvents"
        case run = "run"
        case streaming = "streaming"
        case structuredOutput = "structuredOutput"
        case tools = "tools"
    }

    public init(multimodal: Bool, realtime: Bool, reasoningEvents: Bool, run: Bool, streaming: Bool, structuredOutput: Bool, tools: Bool) {
        self.multimodal = multimodal
        self.realtime = realtime
        self.reasoningEvents = reasoningEvents
        self.run = run
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.tools = tools
    }
}

// MARK: ProviderSupports convenience initializers and mutators

public extension ProviderSupports {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderSupports.self, from: data)
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
        multimodal: Bool? = nil,
        realtime: Bool? = nil,
        reasoningEvents: Bool? = nil,
        run: Bool? = nil,
        streaming: Bool? = nil,
        structuredOutput: Bool? = nil,
        tools: Bool? = nil
    ) -> ProviderSupports {
        return ProviderSupports(
            multimodal: multimodal ?? self.multimodal,
            realtime: realtime ?? self.realtime,
            reasoningEvents: reasoningEvents ?? self.reasoningEvents,
            run: run ?? self.run,
            streaming: streaming ?? self.streaming,
            structuredOutput: structuredOutput ?? self.structuredOutput,
            tools: tools ?? self.tools
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The provider's static capabilities for one task kind.
// MARK: - ProviderTaskCapability
public struct ProviderTaskCapability: Codable, Sendable {
    /// Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
    /// when stopping playback is immediate but a synthesis request cannot be aborted.
    public var cancel: CancelSemantics
    /// Input media kinds the provider accepts for this task.
    public var inputs: [TaskInputKind]
    /// Interaction modes the provider supports for this task.
    public var interaction: ProviderTaskInteraction
    /// The task kind this entry describes, e.g. 'text_to_speech'.
    public var kind: String
    /// BCP 47 locales the provider can serve for this task, when it knows them statically.
    /// Absent means unknown; the dynamic check may report them instead.
    public var locales: [String]?
    /// How results of this task can be delivered. A provider lists only what it really produces:
    /// a provider that can only play audio lists 'playback' and never 'artifact'.
    public var outputs: [ProviderTaskOutput]
    /// Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
    /// provider whose speech synthesis uses a network service. Absent inherits
    /// descriptor.privacy.
    public var privacy: ProviderPrivacy?

    public enum CodingKeys: String, CodingKey {
        case cancel = "cancel"
        case inputs = "inputs"
        case interaction = "interaction"
        case kind = "kind"
        case locales = "locales"
        case outputs = "outputs"
        case privacy = "privacy"
    }

    public init(cancel: CancelSemantics, inputs: [TaskInputKind], interaction: ProviderTaskInteraction, kind: String, locales: [String]?, outputs: [ProviderTaskOutput], privacy: ProviderPrivacy?) {
        self.cancel = cancel
        self.inputs = inputs
        self.interaction = interaction
        self.kind = kind
        self.locales = locales
        self.outputs = outputs
        self.privacy = privacy
    }
}

// MARK: ProviderTaskCapability convenience initializers and mutators

public extension ProviderTaskCapability {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderTaskCapability.self, from: data)
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
        cancel: CancelSemantics? = nil,
        inputs: [TaskInputKind]? = nil,
        interaction: ProviderTaskInteraction? = nil,
        kind: String? = nil,
        locales: [String]?? = nil,
        outputs: [ProviderTaskOutput]? = nil,
        privacy: ProviderPrivacy?? = nil
    ) -> ProviderTaskCapability {
        return ProviderTaskCapability(
            cancel: cancel ?? self.cancel,
            inputs: inputs ?? self.inputs,
            interaction: interaction ?? self.interaction,
            kind: kind ?? self.kind,
            locales: locales ?? self.locales,
            outputs: outputs ?? self.outputs,
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

/// A kind of input medium a task consumes.
public enum TaskInputKind: String, Codable, Sendable {
    case audio = "audio"
    case image = "image"
    case text = "text"
}

/// Interaction modes the provider supports for this task.
// MARK: - ProviderTaskInteraction
public struct ProviderTaskInteraction: Codable, Sendable {
    /// Whether the provider supports Mode 1 run for this task.
    public var run: Bool
    /// Whether the provider supports Mode 2 stream for this task.
    public var stream: Bool

    public enum CodingKeys: String, CodingKey {
        case run = "run"
        case stream = "stream"
    }

    public init(run: Bool, stream: Bool) {
        self.run = run
        self.stream = stream
    }
}

// MARK: ProviderTaskInteraction convenience initializers and mutators

public extension ProviderTaskInteraction {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderTaskInteraction.self, from: data)
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
        run: Bool? = nil,
        stream: Bool? = nil
    ) -> ProviderTaskInteraction {
        return ProviderTaskInteraction(
            run: run ?? self.run,
            stream: stream ?? self.stream
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// One way the provider can deliver a task's result.
// MARK: - ProviderTaskOutput
public struct ProviderTaskOutput: Codable, Sendable {
    public var delivery: OutputDelivery
    /// Media types the provider can produce with this delivery, e.g. 'audio/wav'. Absent means
    /// the provider does not declare them; a request that requires specific media types never
    /// routes to such an output.
    public var mediaTypes: [String]?

    public enum CodingKeys: String, CodingKey {
        case delivery = "delivery"
        case mediaTypes = "mediaTypes"
    }

    public init(delivery: OutputDelivery, mediaTypes: [String]?) {
        self.delivery = delivery
        self.mediaTypes = mediaTypes
    }
}

// MARK: ProviderTaskOutput convenience initializers and mutators

public extension ProviderTaskOutput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderTaskOutput.self, from: data)
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
        delivery: OutputDelivery? = nil,
        mediaTypes: [String]?? = nil
    ) -> ProviderTaskOutput {
        return ProviderTaskOutput(
            delivery: delivery ?? self.delivery,
            mediaTypes: mediaTypes ?? self.mediaTypes
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// How the engine reaches the provider: in-process runtime, operating-system service,
/// buffered HTTP, server-sent events, or a realtime connection.
public enum ProviderTransport: String, Codable, Sendable {
    case http = "http"
    case inProcess = "in_process"
    case realtime = "realtime"
    case sse = "sse"
    case systemService = "system_service"
}

/// Execution placement: 'local' (on the device), 'edge', or 'cloud'.
public enum ProviderType: String, Codable, Sendable {
    case cloud = "cloud"
    case edge = "edge"
    case local = "local"
}

/// Task descriptor for provider task matching: the kind plus the requirements routing can
/// check against declared capabilities. Absent requirement fields are never checked, so a
/// text request carries the kind alone.
// MARK: - RoutePlannerInputTask
public struct RoutePlannerInputTask: Codable, Sendable {
    /// The output delivery the request requires. Absent for text, whose delivery is implicitly
    /// inline.
    public var delivery: DeliveryRequirement?
    /// Input media kinds the request carries. Every one must be accepted by the provider's task
    /// capability. The SDKs send ['text'] for text_to_text.
    public var inputs: [TaskInputKind]?
    /// The task kind, matched against the providers' task capabilities.
    public var kind: String
    /// The locale the request requires. Under 'language' matching the region is a preference: a
    /// provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
    /// that cannot enumerate its locales is not rejected on this basis; it must fail before
    /// committing instead.
    public var locale: LocaleRequirement?
    /// Voice traits the request asks for. Only a 'required' voice can reject a provider; a
    /// 'preferred' one shapes which listed voice the plan binds a candidate to, always within
    /// the request's privacy policy.
    public var voice: VoiceRequirement?

    public enum CodingKeys: String, CodingKey {
        case delivery = "delivery"
        case inputs = "inputs"
        case kind = "kind"
        case locale = "locale"
        case voice = "voice"
    }

    public init(delivery: DeliveryRequirement?, inputs: [TaskInputKind]?, kind: String, locale: LocaleRequirement?, voice: VoiceRequirement?) {
        self.delivery = delivery
        self.inputs = inputs
        self.kind = kind
        self.locale = locale
        self.voice = voice
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
        delivery: DeliveryRequirement?? = nil,
        inputs: [TaskInputKind]?? = nil,
        kind: String? = nil,
        locale: LocaleRequirement?? = nil,
        voice: VoiceRequirement?? = nil
    ) -> RoutePlannerInputTask {
        return RoutePlannerInputTask(
            delivery: delivery ?? self.delivery,
            inputs: inputs ?? self.inputs,
            kind: kind ?? self.kind,
            locale: locale ?? self.locale,
            voice: voice ?? self.voice
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The output delivery the request requires. Absent for text, whose delivery is implicitly
/// inline.
// MARK: - DeliveryRequirement
public struct DeliveryRequirement: Codable, Sendable {
    /// Acceptable media types; the provider must declare at least one for the requested
    /// delivery. Absent means any.
    public var mediaTypes: [String]?
    public var mode: OutputDelivery

    public enum CodingKeys: String, CodingKey {
        case mediaTypes = "mediaTypes"
        case mode = "mode"
    }

    public init(mediaTypes: [String]?, mode: OutputDelivery) {
        self.mediaTypes = mediaTypes
        self.mode = mode
    }
}

// MARK: DeliveryRequirement convenience initializers and mutators

public extension DeliveryRequirement {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DeliveryRequirement.self, from: data)
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
        mediaTypes: [String]?? = nil,
        mode: OutputDelivery? = nil
    ) -> DeliveryRequirement {
        return DeliveryRequirement(
            mediaTypes: mediaTypes ?? self.mediaTypes,
            mode: mode ?? self.mode
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The locale the request requires. Under 'language' matching the region is a preference: a
/// provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
/// that cannot enumerate its locales is not rejected on this basis; it must fail before
/// committing instead.
// MARK: - LocaleRequirement
public struct LocaleRequirement: Codable, Sendable {
    /// 'exact' requires the full tag; 'language' requires only the primary language subtag and
    /// treats the region as a preference.
    public var match: LocaleMatch
    /// BCP 47 tag.
    public var tag: String

    public enum CodingKeys: String, CodingKey {
        case match = "match"
        case tag = "tag"
    }

    public init(match: LocaleMatch, tag: String) {
        self.match = match
        self.tag = tag
    }
}

// MARK: LocaleRequirement convenience initializers and mutators

public extension LocaleRequirement {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(LocaleRequirement.self, from: data)
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
        match: LocaleMatch? = nil,
        tag: String? = nil
    ) -> LocaleRequirement {
        return LocaleRequirement(
            match: match ?? self.match,
            tag: tag ?? self.tag
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Voice traits the request asks for. Only a 'required' voice can reject a provider; a
/// 'preferred' one shapes which listed voice the plan binds a candidate to, always within
/// the request's privacy policy.
// MARK: - VoiceRequirement
public struct VoiceRequirement: Codable, Sendable {
    public var gender: VoiceGender?
    /// 'required' takes part in routing; 'preferred' does not.
    public var requirement: RequirementLevel

    public enum CodingKeys: String, CodingKey {
        case gender = "gender"
        case requirement = "requirement"
    }

    public init(gender: VoiceGender?, requirement: RequirementLevel) {
        self.gender = gender
        self.requirement = requirement
    }
}

// MARK: VoiceRequirement convenience initializers and mutators

public extension VoiceRequirement {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(VoiceRequirement.self, from: data)
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
        gender: VoiceGender?? = nil,
        requirement: RequirementLevel? = nil
    ) -> VoiceRequirement {
        return VoiceRequirement(
            gender: gender ?? self.gender,
            requirement: requirement ?? self.requirement
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
    /// The voice this candidate must use if it is attempted, chosen by the planner from the
    /// provider's dynamic voice inventory. It is the best voice that satisfies the request's
    /// locale, required voice traits and privacy — under local-required privacy always one that
    /// keeps data on the device — ranked by preferred gender, then exact locale region, then
    /// on-device before network. The adapter must use a voice with exactly these traits. Absent
    /// when the request names no locale or voice, or the provider does not list its voices; the
    /// adapter then chooses itself under the same rules.
    public var voice: ProviderVoice?

    public enum CodingKeys: String, CodingKey {
        case order = "order"
        case providerId = "providerId"
        case voice = "voice"
    }

    public init(order: Int, providerId: String, voice: ProviderVoice?) {
        self.order = order
        self.providerId = providerId
        self.voice = voice
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
        providerId: String? = nil,
        voice: ProviderVoice?? = nil
    ) -> Candidate {
        return Candidate(
            order: order ?? self.order,
            providerId: providerId ?? self.providerId,
            voice: voice ?? self.voice
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
    /// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
    /// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
    /// but the dynamic capability snapshot reports it cannot stream in the current host
    /// environment. 'not_in_model_profile' means the request named a model profile that does not
    /// list this provider. 'input_not_supported', 'output_delivery_not_supported',
    /// 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
    /// provider's task capability lacks an input kind, output delivery, media type, locale or
    /// voice the request requires.
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
/// as a hard error. All three engines implement this union (see
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
    /// — providers reporting that style normalize to content_snapshot rather than content_delta.
    /// Retraction: a provider of any streamingStyle may additionally emit a content_snapshot to
    /// withdraw content it has already delivered, since a snapshot replaces the run's cumulative
    /// text rather than appending to it; an empty one therefore resets that text to nothing.
    /// This is how a provider whose backend rejects an in-flight response after partial delivery
    /// — an on-device safety/policy check, for example — tells consumers to discard what they
    /// have, so a consumer must handle content_snapshot even when the provider's declared style
    /// is 'tokens' or 'chunks'.
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
    public var finishReason: FinishReason?
    public var outcome: Outcome?
    public var output: TaskOutput?
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
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
        case finishReason = "finishReason"
        case outcome = "outcome"
        case output = "output"
        case provenance = "provenance"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
        case error = "error"
        case partialText = "partialText"
        case reason = "reason"
    }

    public init(text: String?, phase: Phase?, finalText: String?, finishReason: FinishReason?, outcome: Outcome?, output: TaskOutput?, provenance: ExecutionProvenance?, runId: String?, schemaVersion: SchemaVersion?, telemetry: PayloadTelemetry?, usage: PayloadUsage?, error: PayloadError?, partialText: String?, reason: String?) {
        self.text = text
        self.phase = phase
        self.finalText = finalText
        self.finishReason = finishReason
        self.outcome = outcome
        self.output = output
        self.provenance = provenance
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
        finishReason: FinishReason?? = nil,
        outcome: Outcome?? = nil,
        output: TaskOutput?? = nil,
        provenance: ExecutionProvenance?? = nil,
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
            finishReason: finishReason ?? self.finishReason,
            outcome: outcome ?? self.outcome,
            output: output ?? self.output,
            provenance: provenance ?? self.provenance,
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
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
    public var providerId: String?
    public var retryable: Bool?
    public var retryAfterMs: Int?
    public var schemaVersion: SchemaVersion

    public enum CodingKeys: String, CodingKey {
        case details = "details"
        case errorClass = "errorClass"
        case message = "message"
        case provenance = "provenance"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case schemaVersion = "schemaVersion"
    }

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, provenance: ExecutionProvenance?, providerId: String?, retryable: Bool?, retryAfterMs: Int?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.provenance = provenance
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
        provenance: ExecutionProvenance?? = nil,
        providerId: String?? = nil,
        retryable: Bool?? = nil,
        retryAfterMs: Int?? = nil,
        schemaVersion: SchemaVersion? = nil
    ) -> PayloadError {
        return PayloadError(
            details: details ?? self.details,
            errorClass: errorClass ?? self.errorClass,
            message: message ?? self.message,
            provenance: provenance ?? self.provenance,
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
/// outcome is a fixed architectural guarantee, not something new outcome kinds get added to;
/// the payload of each branch may grow additively). Exactly one StreamTerminalOutcome is
/// produced per run, and no further StreamEvent is delivered after it (see
/// docs/architecture/architecture.md, 'Cancellation And Fallback'). This shape is also
/// embedded by value as the payload of the terminal StreamEvent (stream-event.schema.json)
/// so it can additionally be exposed standalone, e.g. as a completion future/promise a
/// stream handle resolves independently of consuming the full event sequence; the two copies
/// must stay structurally identical. Note on additionalProperties: per this repo's
/// forward-compatible convention every branch permits unknown extra fields, so mutual
/// exclusivity is enforced via the required 'outcome' discriminator plus each branch's own
/// required peer field being present (finalText or output / error), and for 'cancelled' by
/// the discriminator alone, not by forbidding a payload from also carrying an unrelated
/// stray field from another branch's vocabulary.
// MARK: - StreamTerminalOutcome
public struct StreamTerminalOutcome: Codable, Sendable {
    /// The full, cumulative text produced by a text run. Equivalent in role to
    /// TaskResult.output.text for Mode 1. A text run sets it; a non-text run carries output
    /// instead.
    public var finalText: String?
    /// How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
    /// 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
    /// otherwise completed run). 'cancelled' is included so this enum stays identical to
    /// TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
    /// outcome branch. Optional: providers that do not report a finish reason omit it.
    public var finishReason: FinishReason?
    /// The stream completed normally: every provider-generated event was delivered before this
    /// outcome was produced.
    ///
    /// The stream ended in failure: validation, routing (no eligible provider), or every
    /// attempted provider failing.
    ///
    /// The stream was cancelled. No further StreamEvent is delivered after this outcome, and no
    /// further fallback attempt is made, per the engine's cancellation guarantee.
    public var outcome: Outcome
    /// The normalized output of the run, the same shape run() returns in TaskResult.output. Set
    /// for every non-text run; a text run may set it alongside finalText. See
    /// task-output.schema.json.
    ///
    /// What a cancelled non-text run had already produced: a playback run that committed (audio
    /// may have been heard) carries a playback output. Absent when nothing was produced, e.g. an
    /// artifact run cancelled before its artifact was handed over, whose partial media the
    /// engine discards. See task-output.schema.json.
    public var output: TaskOutput?
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
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
    /// Whatever cumulative text a text run had already delivered before it failed after
    /// committing to its provider. Absent when nothing was delivered.
    ///
    /// Whatever cumulative text a text run had already delivered via
    /// content_delta/content_snapshot StreamEvents before the cancellation point. Always set for
    /// a text run, and empty if cancellation occurred before any content was produced. A
    /// non-text run never sets it.
    public var partialText: String?
    /// Optional human-readable reason the run was cancelled (e.g. caller-initiated abort). Not a
    /// machine-taxonomy field; use errorClass on the 'error' outcome branch for failure
    /// classification.
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case finalText = "finalText"
        case finishReason = "finishReason"
        case outcome = "outcome"
        case output = "output"
        case provenance = "provenance"
        case runId = "runId"
        case schemaVersion = "schemaVersion"
        case telemetry = "telemetry"
        case usage = "usage"
        case error = "error"
        case partialText = "partialText"
        case reason = "reason"
    }

    public init(finalText: String?, finishReason: FinishReason?, outcome: Outcome, output: TaskOutput?, provenance: ExecutionProvenance?, runId: String, schemaVersion: SchemaVersion, telemetry: StreamTerminalOutcomeTelemetry?, usage: StreamTerminalOutcomeUsage?, error: StreamTerminalOutcomeError?, partialText: String?, reason: String?) {
        self.finalText = finalText
        self.finishReason = finishReason
        self.outcome = outcome
        self.output = output
        self.provenance = provenance
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
        finishReason: FinishReason?? = nil,
        outcome: Outcome? = nil,
        output: TaskOutput?? = nil,
        provenance: ExecutionProvenance?? = nil,
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
            finishReason: finishReason ?? self.finishReason,
            outcome: outcome ?? self.outcome,
            output: output ?? self.output,
            provenance: provenance ?? self.provenance,
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
    /// Normalized execution provenance: which target ran, its declared locality, the configured
    /// and reported model, and how fallback and routing played out. See
    /// execution-provenance.schema.json.
    public var provenance: ExecutionProvenance?
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
        case provenance = "provenance"
        case providerId = "providerId"
        case retryable = "retryable"
        case retryAfterMs = "retryAfterMs"
        case schemaVersion = "schemaVersion"
    }

    public init(details: [String: JSONAny]?, errorClass: ErrorClass, message: String, provenance: ExecutionProvenance?, providerId: String?, retryable: Bool?, retryAfterMs: Int?, schemaVersion: SchemaVersion) {
        self.details = details
        self.errorClass = errorClass
        self.message = message
        self.provenance = provenance
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
        provenance: ExecutionProvenance?? = nil,
        providerId: String?? = nil,
        retryable: Bool?? = nil,
        retryAfterMs: Int?? = nil,
        schemaVersion: SchemaVersion? = nil
    ) -> StreamTerminalOutcomeError {
        return StreamTerminalOutcomeError(
            details: details ?? self.details,
            errorClass: errorClass ?? self.errorClass,
            message: message ?? self.message,
            provenance: provenance ?? self.provenance,
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

/// One registered provider's identity, static declaration and live capability check, as
/// returned by checkCapabilities(). A read-only snapshot: producing it executes no task and
/// has no side effects.
// MARK: - ProviderCapabilitySnapshot
public struct ProviderCapabilitySnapshot: Codable, Sendable {
    /// The provider's live capability check at the time of the call.
    public var capabilities: ProviderDynamicCapabilities
    /// The provider's static capability declaration.
    public var descriptor: ProviderDescriptor
    /// Identifier of the provider; equal to descriptor.id.
    public var providerId: String

    public enum CodingKeys: String, CodingKey {
        case capabilities = "capabilities"
        case descriptor = "descriptor"
        case providerId = "providerId"
    }

    public init(capabilities: ProviderDynamicCapabilities, descriptor: ProviderDescriptor, providerId: String) {
        self.capabilities = capabilities
        self.descriptor = descriptor
        self.providerId = providerId
    }
}

// MARK: ProviderCapabilitySnapshot convenience initializers and mutators

public extension ProviderCapabilitySnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderCapabilitySnapshot.self, from: data)
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
        capabilities: ProviderDynamicCapabilities? = nil,
        descriptor: ProviderDescriptor? = nil,
        providerId: String? = nil
    ) -> ProviderCapabilitySnapshot {
        return ProviderCapabilitySnapshot(
            capabilities: capabilities ?? self.capabilities,
            descriptor: descriptor ?? self.descriptor,
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

/// A ranged read of an engine-owned media artifact through IndeRunApi.readArtifact (ADR
/// 017). Reads are repeatable until the artifact is disposed; each returns at most the
/// engine's configured maximum read size, which bounds what one call -- and one bridge
/// message -- carries.
// MARK: - ArtifactReadRequest
public struct ArtifactReadRequest: Codable, Sendable {
    /// MediaArtifact.id of the artifact to read.
    public var artifactId: String
    /// Most bytes to return. Absent, or larger than the engine's maximum read size, means that
    /// maximum.
    public var maxBytes: Int?
    /// Byte offset to read from. Absent means 0. An offset equal to the artifact's size returns
    /// an empty, final chunk; a larger one is rejected.
    public var offset: Int?

    public enum CodingKeys: String, CodingKey {
        case artifactId = "artifactId"
        case maxBytes = "maxBytes"
        case offset = "offset"
    }

    public init(artifactId: String, maxBytes: Int?, offset: Int?) {
        self.artifactId = artifactId
        self.maxBytes = maxBytes
        self.offset = offset
    }
}

// MARK: ArtifactReadRequest convenience initializers and mutators

public extension ArtifactReadRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ArtifactReadRequest.self, from: data)
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
        artifactId: String? = nil,
        maxBytes: Int?? = nil,
        offset: Int?? = nil
    ) -> ArtifactReadRequest {
        return ArtifactReadRequest(
            artifactId: artifactId ?? self.artifactId,
            maxBytes: maxBytes ?? self.maxBytes,
            offset: offset ?? self.offset
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
