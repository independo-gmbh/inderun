import Foundation
import IndeRunContracts

/// The generated `Payload` is the flattened union of every `StreamEvent` variant's
/// payload, so constructing one means naming every field. These factories
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
            output: nil,
            provenance: nil,
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
            output: outcome.output,
            provenance: outcome.provenance,
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
                    provenance: $0.provenance,
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
    /// A text run carries `finalText`; a run that ended with a normalized output carries
    /// `output`, and also `finalText` when that output is text.
    public static func completed( // swiftlint:disable:this function_parameter_count
        runId: String,
        finalText: String?,
        output: TaskOutput? = nil,
        finishReason: FinishReason?,
        usage: TaskResultUsage?,
        telemetry: StreamTerminalOutcomeTelemetry,
        provenance: ExecutionProvenance
    ) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: finalText,
            finishReason: finishReason,
            outcome: .completed,
            output: output,
            provenance: provenance,
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
    /// `partialText` is set for a text run only.
    public static func failed(
        runId: String,
        error: IndeRunError,
        partialText: String?,
        provenance: ExecutionProvenance
    ) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: nil,
            finishReason: nil,
            outcome: .error,
            output: nil,
            provenance: provenance,
            runId: runId,
            schemaVersion: .the10,
            telemetry: nil,
            usage: nil,
            error: StreamTerminalOutcomeError(
                details: error.details,
                errorClass: error.errorClass,
                message: error.message,
                provenance: error.provenance,
                providerId: error.providerId,
                retryable: error.retryable,
                retryAfterMs: error.retryAfterMs,
                schemaVersion: error.schemaVersion
            ),
            partialText: partialText,
            reason: nil
        )
    }

    /// The `cancelled` outcome, carrying whatever content was delivered first: `partialText`
    /// for a text run, `output` for a non-text run that had already produced something
    /// (committed playback), neither for a non-text run that had not.
    public static func cancelled(
        runId: String,
        partialText: String?,
        output: TaskOutput? = nil,
        reason: String?,
        provenance: ExecutionProvenance
    ) -> StreamTerminalOutcome {
        StreamTerminalOutcome(
            finalText: nil,
            finishReason: nil,
            outcome: .cancelled,
            output: output,
            provenance: provenance,
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
