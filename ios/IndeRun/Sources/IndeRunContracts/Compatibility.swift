import Foundation

public typealias TaskDescriptor = TaskRequestTask
public typealias GenerationHints = Generation
public typealias TelemetryPreferences = TaskRequestTelemetry
public typealias UsageInfo = Usage
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
        generation: GenerationHints? = nil,
        policy: Policy,
        telemetry: TelemetryPreferences? = nil,
        authContextRef: String? = nil
    ) {
        self.init(
            authContextRef: authContextRef,
            generation: generation,
            messages: messages,
            policy: policy,
            prompt: prompt,
            requestId: requestId,
            schemaVersion: SchemaVersion(rawValue: schemaVersion) ?? .the10,
            task: task,
            telemetry: telemetry
        )
    }
}

public extension Message {
    init(role: Role, content: String) {
        self.init(content: content, role: role)
    }
}

public extension Output {
    init(type: String = "text", text: String) {
        self.init(text: text, type: OutputType(rawValue: type) ?? .text)
    }
}

public extension TaskResult {
    init(
        schemaVersion: String = "1.0",
        runId: String,
        output: Output,
        finishReason: FinishReason,
        usage: UsageInfo? = nil,
        telemetry: TelemetryInfo
    ) {
        self.init(
            finishReason: finishReason,
            output: output,
            runId: runId,
            schemaVersion: SchemaVersion(rawValue: schemaVersion) ?? .the10,
            telemetry: telemetry,
            usage: usage
        )
    }
}

public extension TaskResultTelemetry {
    init(providerUsed: String, totalMs: Double, errorClass: IndeRunErrorClass? = nil) {
        self.init(errorClass: errorClass, providerUsed: providerUsed, totalMs: totalMs)
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
        details: [String: JSONAny]? = nil
    ) {
        self.init(
            details: details,
            errorClass: errorClass,
            message: message,
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
