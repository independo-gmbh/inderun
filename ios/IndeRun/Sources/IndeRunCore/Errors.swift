import Foundation
import IndeRunContracts

public struct IndeRunException: Error, CustomStringConvertible, Sendable {
    public let schemaVersion: String = "1.0"
    public let errorClass: IndeRunErrorClass
    public let message: String
    public let runId: String?
    public let providerId: String?
    public let retryable: Bool?
    public let retryAfterMs: Int?
    public let details: [String: JSONAny]?

    public var description: String {
        return "[\(errorClass.rawValue)] \(message)"
    }

    public init(
        errorClass: IndeRunErrorClass,
        message: String,
        runId: String? = nil,
        providerId: String? = nil,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil,
        details: [String: JSONAny]? = nil
    ) {
        self.errorClass = errorClass
        self.message = message
        self.runId = runId
        self.providerId = providerId
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.details = details
    }

    public func toContractError() -> IndeRunError {
        return IndeRunError(
            schemaVersion: schemaVersion,
            errorClass: errorClass,
            message: message,
            runId: runId,
            providerId: providerId,
            retryable: retryable,
            retryAfterMs: retryAfterMs,
            details: details
        )
    }
}

// MARK: - Factory Helpers
public func createCapabilityMismatch(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .CapabilityMismatch,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createOffline(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .Offline,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createAuthError(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .AuthError,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createRateLimited(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .RateLimited,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createTimeout(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .Timeout,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createUnavailable(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .Unavailable,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

public func createInternal(
    message: String,
    runId: String? = nil,
    providerId: String? = nil,
    retryable: Bool? = nil,
    retryAfterMs: Int? = nil,
    details: [String: JSONAny]? = nil
) -> IndeRunException {
    return IndeRunException(
        errorClass: .Internal,
        message: message,
        runId: runId,
        providerId: providerId,
        retryable: retryable,
        retryAfterMs: retryAfterMs,
        details: details
    )
}

// MARK: - Error Standardization
public func toIndeRunException(
    _ error: Error,
    fallbackRunId: String? = nil,
    fallbackProviderId: String? = nil,
    fallbackRetryable: Bool? = nil,
    fallbackRetryAfterMs: Int? = nil,
    fallbackDetails: [String: JSONAny]? = nil
) -> IndeRunException {
    if let exc = error as? IndeRunException {
        var mergedDetails = exc.details ?? [:]
        if let fallback = fallbackDetails {
            mergedDetails.merge(fallback) { (current, _) in current }
        }
        return IndeRunException(
            errorClass: exc.errorClass,
            message: exc.message,
            runId: exc.runId ?? fallbackRunId,
            providerId: exc.providerId ?? fallbackProviderId,
            retryable: exc.retryable ?? fallbackRetryable,
            retryAfterMs: exc.retryAfterMs ?? fallbackRetryAfterMs,
            details: mergedDetails.isEmpty ? nil : mergedDetails
        )
    }

    var details: [String: JSONAny] = fallbackDetails ?? [:]
    details["originalError"] = JSONAny(error.localizedDescription)

    return IndeRunException(
        errorClass: .Internal,
        message: error.localizedDescription,
        runId: fallbackRunId,
        providerId: fallbackProviderId,
        retryable: fallbackRetryable,
        retryAfterMs: fallbackRetryAfterMs,
        details: details
    )
}
