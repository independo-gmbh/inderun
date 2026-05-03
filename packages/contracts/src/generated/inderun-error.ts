/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Normalized Milestone-1 error contract.
 */
export interface IndeRunError {
  schemaVersion: "1.0";
  errorClass:
    | "CapabilityMismatch"
    | "Offline"
    | "AuthError"
    | "RateLimited"
    | "Timeout"
    | "Unavailable"
    | "Internal";
  message: string;
  runId?: string;
  providerId?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  details?: {
    [k: string]: unknown;
  };
  [k: string]: unknown;
}
