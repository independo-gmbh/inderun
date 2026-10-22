import Foundation

public typealias TaskDescriptor = TaskRequestTask
public typealias GenerationHints = Generation
public typealias TelemetryPreferences = TaskRequestTelemetry
public typealias UsageInfo = TaskResultUsage
public typealias TelemetryInfo = TaskResultTelemetry
public typealias IndeRunErrorClass = ErrorClass
public typealias TelemetryValue = JSONAny

extension JSONAny: @unchecked Sendable {}
extension JSONNull: @unchecked Sendable {}

public extension TaskRequest {
    init(
        schemaVersion: String = "1.0",
        requestId: String? = nil,
        task: TaskDescriptor = TaskDescriptor(kind: .textToText),
        prompt: String? = nil,
        messages: [Message]? = nil,
        modelProfile: String? = nil,
        generation: GenerationHints? = nil,
        constraints: TaskRequestConstraints? = nil,
        preferences: TaskRequestPreferences? = nil,
        telemetry: TelemetryPreferences? = nil,
        authContextRef: String? = nil,
        speech: SpeechInput? = nil,
        delivery: OutputDeliveryRequest? = nil
    ) {
        self.init(
            authContextRef: authContextRef,
            constraints: constraints,
            delivery: delivery,
            generation: generation,
            messages: messages,
            modelProfile: modelProfile,
            preferences: preferences,
            prompt: prompt,
            requestId: requestId,
            schemaVersion: SchemaVersion(rawValue: schemaVersion) ?? .the10,
            speech: speech,
            task: task,
            telemetry: telemetry
        )
    }
}

/// The generated memberwise initializer takes every field, in the schema's
/// alphabetical order. Constraints are almost always set one at a time (a privacy
/// floor, a timeout), so this mirrors the other convenience initializers here and
/// lets callers name only what they are constraining.
public extension TaskRequestConstraints {
    init(privacy: Privacy? = nil, cloud: Cloud? = nil, timeoutMs: Int? = nil) {
        self.init(cloud: cloud, privacy: privacy, timeoutMs: timeoutMs)
    }
}

public extension Message {
    init(role: Role, content: String) {
        self.init(content: content, role: role)
    }
}

/// One initializer per output representation (ADR 016), so a caller cannot build a
/// `.playback` output without its payload or a `.text` output without its text.
public extension TaskOutput {
    /// Inline text.
    init(text: String) {
        self.init(artifact: nil, playback: nil, speech: nil, text: text, type: .text)
    }

    /// Completion of managed playback; carries no media.
    init(playback: PlaybackOutput, speech: SpeechOutput? = nil) {
        self.init(artifact: nil, playback: playback, speech: speech, text: nil, type: .playback)
    }

    /// A reference to retrievable media (ADR 017).
    init(artifact: MediaArtifact, speech: SpeechOutput? = nil) {
        self.init(artifact: artifact, playback: nil, speech: speech, text: nil, type: .artifact)
    }
}

public extension TaskResult {
    init(
        schemaVersion: String = "1.0",
        runId: String,
        output: TaskOutput,
        finishReason: FinishReason,
        usage: UsageInfo? = nil,
        telemetry: TelemetryInfo,
        provenance: ExecutionProvenance? = nil
    ) {
        self.init(
            finishReason: finishReason,
            output: output,
            provenance: provenance,
            runId: runId,
            schemaVersion: SchemaVersion(rawValue: schemaVersion) ?? .the10,
            telemetry: telemetry,
            usage: usage
        )
    }
}

public extension TaskResultTelemetry {
    init(
        providerUsed: String,
        totalMs: Double,
        errorClass: IndeRunErrorClass? = nil,
        reportedModel: String? = nil
    ) {
        self.init(
            errorClass: errorClass,
            providerUsed: providerUsed,
            reportedModel: reportedModel,
            totalMs: totalMs
        )
    }
}

public extension IndeRunError {
    init(
        schemaVersion: String = "1.0",
        errorClass: IndeRunErrorClass,
        message: String,
        runId: String? = nil,
        providerId: String? = nil,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil,
        details: [String: JSONAny]? = nil,
        provenance: ExecutionProvenance? = nil
    ) {
        self.init(
            details: details,
            errorClass: errorClass,
            message: message,
            provenance: provenance,
            providerId: providerId,
            retryable: retryable,
            retryAfterMs: retryAfterMs,
            runId: runId,
            schemaVersion: SchemaVersion(rawValue: schemaVersion) ?? .the10
        )
    }
}

public extension HttpRequest {
    init(
        method: Method,
        url: String,
        headers: [String: String]? = nil,
        body: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.init(body: body, headers: headers, method: method, timeoutMs: timeoutMs, url: url)
    }
}

public extension HttpResponse {
    init(status: Int, statusText: String, headers: [String: String], body: String) {
        self.init(body: body, headers: headers, status: status, statusText: statusText)
    }
}

public extension TelemetryEvent {
    init(type: String, runId: String, timestamp: Int64, payload: [String: TelemetryValue]) {
        self.init(
            payload: payload,
            runId: runId,
            timestamp: Double(timestamp),
            type: TelemetryEventType(rawValue: type) ?? .routeDecided
        )
    }
}

// MARK: - Provider capability contracts

// The generated memberwise initializers take every field in alphabetical order with no
// defaults. These keep provider declarations in the order a descriptor is read — identity,
// placement, transport, modes, cancellation, tasks — and let optional fields be omitted.

public extension ProviderDescriptor {
    init(
        id: String,
        type: ProviderType,
        model: String? = nil,
        transport: ProviderTransport,
        streamingStyle: StreamingStyle? = nil,
        supports: ProviderSupports,
        cancel: CancelSemantics,
        tasks: [String],
        taskCapabilities: [ProviderTaskCapability]? = nil,
        limits: ProviderLimits? = nil,
        privacy: ProviderPrivacy? = nil
    ) {
        self.init(
            cancel: cancel,
            id: id,
            limits: limits,
            model: model,
            privacy: privacy,
            streamingStyle: streamingStyle,
            supports: supports,
            taskCapabilities: taskCapabilities,
            tasks: tasks,
            transport: transport,
            type: type
        )
    }
}

public extension ProviderSupports {
    init(
        run: Bool,
        streaming: Bool,
        realtime: Bool,
        tools: Bool,
        reasoningEvents: Bool,
        structuredOutput: Bool,
        multimodal: Bool
    ) {
        self.init(
            multimodal: multimodal,
            realtime: realtime,
            reasoningEvents: reasoningEvents,
            run: run,
            streaming: streaming,
            structuredOutput: structuredOutput,
            tools: tools
        )
    }
}

public extension ProviderLimits {
    init(
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        maxImageBytes: Int? = nil,
        maxAudioSeconds: Int? = nil
    ) {
        self.init(
            maxAudioSeconds: maxAudioSeconds,
            maxImageBytes: maxImageBytes,
            maxInputTokens: maxInputTokens,
            maxOutputTokens: maxOutputTokens
        )
    }
}

public extension ProviderPrivacy {
    /// A privacy declaration without regions. The generated initializer already takes
    /// `(dataLeavesDevice:regions:)` in that order, so only the shorter form is added here.
    init(dataLeavesDevice: Bool) {
        self.init(dataLeavesDevice: dataLeavesDevice, regions: nil)
    }
}

public extension ProviderDynamicCapabilities {
    /// Omitted tri-state fields stay `nil`, which encodes as an absent key: absent
    /// `streamingAvailable` / `cancellationAvailable` inherit the static declaration.
    init(
        available: Bool,
        reason: String? = nil,
        streamingAvailable: Bool? = nil,
        streamingUnavailableReason: String? = nil,
        cancellationAvailable: Bool? = nil,
        taskCapabilities: [ProviderTaskAvailability]? = nil
    ) {
        self.init(
            available: available,
            cancellationAvailable: cancellationAvailable,
            reason: reason,
            streamingAvailable: streamingAvailable,
            streamingUnavailableReason: streamingUnavailableReason,
            taskCapabilities: taskCapabilities
        )
    }
}

public extension ProviderTaskCapability {
    init(
        kind: String,
        inputs: [TaskInputKind],
        interaction: ProviderTaskInteraction,
        cancel: CancelSemantics,
        outputs: [ProviderTaskOutput],
        locales: [String]? = nil,
        privacy: ProviderPrivacy? = nil
    ) {
        self.init(
            cancel: cancel,
            inputs: inputs,
            interaction: interaction,
            kind: kind,
            locales: locales,
            outputs: outputs,
            privacy: privacy
        )
    }
}

public extension ProviderTaskOutput {
    /// An output that does not declare its media types, e.g. managed playback.
    init(delivery: OutputDelivery) {
        self.init(delivery: delivery, mediaTypes: nil)
    }
}

public extension ProviderTaskAvailability {
    /// Omitted fields stay `nil` and inherit the provider-level check.
    init(
        kind: String,
        available: Bool? = nil,
        reason: String? = nil,
        streamingAvailable: Bool? = nil,
        streamingUnavailableReason: String? = nil,
        cancellationAvailable: Bool? = nil,
        locales: [String]? = nil,
        voices: [ProviderVoice]? = nil
    ) {
        self.init(
            available: available,
            cancellationAvailable: cancellationAvailable,
            kind: kind,
            locales: locales,
            reason: reason,
            streamingAvailable: streamingAvailable,
            streamingUnavailableReason: streamingUnavailableReason,
            voices: voices
        )
    }
}

public extension ProviderVoice {
    init(locale: String, gender: VoiceGender? = nil, networkRequired: Bool? = nil) {
        self.init(gender: gender, locale: locale, networkRequired: networkRequired)
    }
}

public extension ProviderCapabilitySnapshot {
    init(providerId: String, descriptor: ProviderDescriptor, capabilities: ProviderDynamicCapabilities) {
        self.init(capabilities: capabilities, descriptor: descriptor, providerId: providerId)
    }
}
