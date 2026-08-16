import type { IndeRunError, IndeRunErrorClass } from "@independo/inderun-contracts";

/**
 * Parameter structure required to initialize an IndeRunException.
 */
export interface IndeRunExceptionParams {
  /**
   * The standardized error class (e.g. 'CapabilityMismatch', 'Offline').
   */
  errorClass: IndeRunErrorClass;
  /**
   * Explanatory human-readable message.
   */
  message: string;
  /**
   * The unique run ID where this exception occurred.
   */
  runId?: string;
  /**
   * The provider ID that triggered the exception, if execution reached a provider.
   */
  providerId?: string;
  /**
   * Whether the client should retry this request.
   */
  retryable?: boolean;
  /**
   * Backoff time suggestion in milliseconds before retrying.
   */
  retryAfterMs?: number;
  /**
   * Rich contextual metadata regarding the error.
   */
  details?: Record<string, unknown>;
}

/**
 * Standardized framework exception thrown when route selection or provider execution fails.
 * Extends the native JavaScript Error class and exposes normalized error schema fields.
 */
export class IndeRunException extends Error {
  /** The schema version matching the API contracts. */
  readonly schemaVersion = "1.0";
  /** The categorized class of error. */
  readonly errorClass: IndeRunErrorClass;
  /** The unique execution run ID. */
  readonly runId?: string;
  /** The provider ID responsible for the error. */
  readonly providerId?: string;
  /** Whether the error is transient and retryable. */
  readonly retryable?: boolean;
  /** Suggested cooling-down time in milliseconds before retry. */
  readonly retryAfterMs?: number;
  /** Custom details and metadata context. */
  readonly details?: Record<string, unknown>;

  constructor(params: IndeRunExceptionParams) {
    super(params.message);
    this.name = "IndeRunException";
    this.errorClass = params.errorClass;
    if (params.runId !== undefined) this.runId = params.runId;
    if (params.providerId !== undefined) this.providerId = params.providerId;
    if (params.retryable !== undefined) this.retryable = params.retryable;
    if (params.retryAfterMs !== undefined) this.retryAfterMs = params.retryAfterMs;
    if (params.details !== undefined) this.details = params.details;

    Object.setPrototypeOf(this, IndeRunException.prototype);
  }

  /**
   * Converts the exception into a JSON-compatible contract-compliant IndeRunError.
   */
  toContractError(): IndeRunError {
    const err: IndeRunError = {
      schemaVersion: this.schemaVersion,
      errorClass: this.errorClass,
      message: this.message
    };
    if (this.runId !== undefined) err.runId = this.runId;
    if (this.providerId !== undefined) err.providerId = this.providerId;
    if (this.retryable !== undefined) err.retryable = this.retryable;
    if (this.retryAfterMs !== undefined) err.retryAfterMs = this.retryAfterMs;
    if (this.details !== undefined) err.details = this.details;
    return err;
  }
}

/**
 * Factory helper for CapabilityMismatch error class.
 */
export function createCapabilityMismatch(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "CapabilityMismatch", message, ...extra });
}

/**
 * Factory helper for Offline error class.
 */
export function createOffline(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "Offline", message, ...extra });
}

/**
 * Factory helper for AuthError error class.
 */
export function createAuthError(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "AuthError", message, ...extra });
}

/**
 * Factory helper for RateLimited error class.
 */
export function createRateLimited(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "RateLimited", message, ...extra });
}

/**
 * Factory helper for Timeout error class.
 */
export function createTimeout(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "Timeout", message, ...extra });
}

/**
 * Factory helper for Unavailable error class.
 */
export function createUnavailable(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "Unavailable", message, ...extra });
}

/**
 * Factory helper for Internal error class.
 */
export function createInternal(
  message: string,
  extra?: Omit<IndeRunExceptionParams, "errorClass" | "message">
): IndeRunException {
  return new IndeRunException({ errorClass: "Internal", message, ...extra });
}

/**
 * Standardizes any caught error into an IndeRunException.
 * If the input error is already an IndeRunException, merges additional fallback parameters (like totalMs).
 */
export function toIndeRunException(
  error: unknown,
  fallbackParams?: Partial<Omit<IndeRunExceptionParams, "message">>
): IndeRunException {
  if (error instanceof IndeRunException) {
    if (fallbackParams) {
      const mergedParams: IndeRunExceptionParams = {
        errorClass: error.errorClass,
        message: error.message
      };

      const runId = error.runId ?? fallbackParams.runId;
      if (runId !== undefined) mergedParams.runId = runId;

      const providerId = error.providerId ?? fallbackParams.providerId;
      if (providerId !== undefined) mergedParams.providerId = providerId;

      const retryable = error.retryable ?? fallbackParams.retryable;
      if (retryable !== undefined) mergedParams.retryable = retryable;

      const retryAfterMs = error.retryAfterMs ?? fallbackParams.retryAfterMs;
      if (retryAfterMs !== undefined) mergedParams.retryAfterMs = retryAfterMs;

      if (error.details !== undefined || fallbackParams.details !== undefined) {
        mergedParams.details = {
          ...(error.details || {}),
          ...(fallbackParams.details || {})
        };
      }

      return new IndeRunException(mergedParams);
    }
    return error;
  }

  const message = error instanceof Error ? error.message : String(error);
  const details: Record<string, unknown> = {
    ...(fallbackParams?.details || {})
  };

  if (error instanceof Error) {
    details.originalError = {
      name: error.name,
      message: error.message,
      stack: error.stack
    };
  } else {
    details.originalError = {
      message: String(error)
    };
  }

  return new IndeRunException({
    errorClass: "Internal",
    message,
    ...fallbackParams,
    details
  });
}
