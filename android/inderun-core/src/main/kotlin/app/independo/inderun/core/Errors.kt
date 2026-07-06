package app.independo.inderun.core

import app.independo.inderun.contracts.IndeRunError
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.SchemaVersion

class IndeRunException(
    val errorClass: IndeRunErrorClass,
    override val message: String,
    val runId: String? = null,
    val providerId: String? = null,
    val retryable: Boolean? = null,
    val retryAfterMs: Long? = null,
    val details: Map<String, Any?>? = null,
) : Exception(message) {
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0

    fun toContractError(): IndeRunError = IndeRunError(
        errorClass = errorClass,
        message = message,
        runId = runId,
        providerId = providerId,
        retryable = retryable,
        retryAfterMs = retryAfterMs,
        details = details,
        schemaVersion = schemaVersion,
    )
}

fun createCapabilityMismatch(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.CapabilityMismatch,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createOffline(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.Offline,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createAuthError(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.AuthError,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createRateLimited(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.RateLimited,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createTimeout(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.Timeout,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createUnavailable(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.Unavailable,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun createInternal(
    message: String,
    runId: String? = null,
    providerId: String? = null,
    retryable: Boolean? = null,
    retryAfterMs: Long? = null,
    details: Map<String, Any?>? = null,
): IndeRunException = IndeRunException(
    errorClass = IndeRunErrorClass.Internal,
    message = message,
    runId = runId,
    providerId = providerId,
    retryable = retryable,
    retryAfterMs = retryAfterMs,
    details = details,
)

fun toIndeRunException(
    error: Throwable,
    fallbackRunId: String? = null,
    fallbackProviderId: String? = null,
    fallbackRetryable: Boolean? = null,
    fallbackRetryAfterMs: Long? = null,
    fallbackDetails: Map<String, Any?>? = null,
): IndeRunException {
    if (error is IndeRunException) {
        val mergedDetails = buildMap<String, Any?> {
            putAll(fallbackDetails ?: emptyMap())
            putAll(error.details ?: emptyMap())
        }.ifEmpty { null }

        return IndeRunException(
            errorClass = error.errorClass,
            message = error.message,
            runId = error.runId ?: fallbackRunId,
            providerId = error.providerId ?: fallbackProviderId,
            retryable = error.retryable ?: fallbackRetryable,
            retryAfterMs = error.retryAfterMs ?: fallbackRetryAfterMs,
            details = mergedDetails,
        )
    }

    val details = buildMap<String, Any?> {
        putAll(fallbackDetails ?: emptyMap())
        put("originalError", error.localizedMessage)
    }

    return IndeRunException(
        errorClass = IndeRunErrorClass.Internal,
        message = error.localizedMessage ?: error.toString(),
        runId = fallbackRunId,
        providerId = fallbackProviderId,
        retryable = fallbackRetryable,
        retryAfterMs = fallbackRetryAfterMs,
        details = details,
    )
}
