import Foundation
import IndeRunContracts

/// The generated `Payload` is the flattened union of every `StreamEvent` variant's
/// payload, so constructing one means naming all twelve fields. These factories
/// keep that noise out of the orchestrator and, more importantly, keep the
/// terminal payload a faithful copy of ``StreamTerminalOutcome`` — the two shapes
/// are required by contract to stay structurally identical.
extension Payload {
    /// Payload for a `content_delta` / `content_snapshot` event.
    public static func content(text: String) -> Payload {
        Payload(
            text: text,
            phase: nil,
            finalText: nil,
            finishReason: nil,
            outcome: nil,
            runId: nil,
            schemaVersion: nil,
            telemetry: nil,
            usage: nil,
            error: nil,
            partialText: nil,
            reason: nil
        )
    }

    /// Payload for the terminal event, mirroring the standalone outcome by value.
    public init(terminalOutcome outcome: StreamTerminalOutcome) {
        self.init(
            text: nil,
            phase: nil,
            finalText: outcome.finalText,
            finishReason: outcome.finishReason,
            outcome: outcome.outcome,
            runId: outcome.runId,
            schemaVersion: outcome.schemaVersion,
            telemetry: outcome.telemetry.map {
                PayloadTelemetry(providerUsed: $0.providerUsed, totalMs: $0.totalMs)
            },
            usage: outcome.usage.map {
                PayloadUsage(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    totalTokens: $0.totalTokens
                )
            },
            error: outcome.error.map {
                PayloadError(
                    details: $0.details,
                    errorClass: $0.errorClass,
                    message: $0.message,
                    providerId: $0.providerId,
                    retryable: $0.retryable,
                    retryAfterMs: $0.retryAfterMs,
                    schemaVersion: $0.schemaVersion
                )
            },
            partialText: outcome.partialText,
            reason: outcome.reason
        )
    }
}

extension StreamTerminalOutcome {
    /// The `completed` outcome: the provider delivered every event it was going to.
    public static func completed(
        runId: String,
        finalText: String,
        finishReason: FinishReason?,
        usage: TaskResultUsage?,
        telemetry: StreamTerminalOutcomeTelemetry
    ) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: finalText,
            finishReason: finishReason,
            outcome: .completed,
            runId: runId,
            schemaVersion: .the10,
            telemetry: telemetry,
            usage: usage.map {
                StreamTerminalOutcomeUsage(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    totalTokens: $0.totalTokens
                )
            },
            error: nil,
            partialText: nil,
            reason: nil
        )
    }

    /// The `error` outcome: validation, routing, or every attempted provider failing.
    public static func failed(runId: String, error: IndeRunError, partialText: String) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: nil,
            finishReason: nil,
            outcome: .error,
            runId: runId,
            schemaVersion: .the10,
            telemetry: nil,
            usage: nil,
            error: StreamTerminalOutcomeError(
                details: error.details,
                errorClass: error.errorClass,
                message: error.message,
                providerId: error.providerId,
                retryable: error.retryable,
                retryAfterMs: error.retryAfterMs,
                schemaVersion: error.schemaVersion
            ),
            partialText: partialText,
            reason: nil
        )
    }

    /// The `cancelled` outcome, carrying whatever content was delivered first.
    public static func cancelled(runId: String, partialText: String, reason: String?) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: nil,
            finishReason: nil,
            outcome: .cancelled,
            runId: runId,
            schemaVersion: .the10,
            telemetry: nil,
            usage: nil,
            error: nil,
            partialText: partialText,
            reason: reason
        )
    }
}
