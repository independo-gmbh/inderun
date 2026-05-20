/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Normalized Milestone-1 error contract.
 */
export interface IndeRunError {
  /**
   * Contract schema version used to interpret the error payload.
   */
  schemaVersion: "1.0";
  /**
   * Normalized error taxonomy class.
   */
  errorClass:
    | "CapabilityMismatch"
    | "Offline"
    | "AuthError"
    | "RateLimited"
    | "Timeout"
    | "Unavailable"
    | "Internal";
  /**
   * Human-readable error message suitable for logs and developer diagnostics.
   */
  message: string;
  /**
   * Opaque run identifier associated with the failed execution, if available.
   */
  runId?: string;
  /**
   * Identifier of the provider associated with the failure, if execution reached a provider.
   */
  providerId?: string;
  /**
   * Whether retrying the same request may succeed.
   */
  retryable?: boolean;
  /**
   * Optional suggested delay before retrying, in milliseconds.
   */
  retryAfterMs?: number;
  /**
   * Optional structured diagnostic details. It must not contain raw secrets.
   */
  details?: {
    [k: string]: unknown;
  };
  [k: string]: unknown;
}
