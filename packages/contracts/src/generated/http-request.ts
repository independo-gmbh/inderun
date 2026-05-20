/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Normalized HTTP request payload for host-provided cloud transport.
 */
export interface HttpRequest {
  /**
   * HTTP method to use for the request.
   */
  method: "GET" | "POST" | "PUT" | "DELETE" | "PATCH";
  /**
   * Absolute target URL for the provider transport request.
   */
  url: string;
  /**
   * HTTP headers to send after the provider adapter has applied any required transport-level credentials.
   */
  headers?: {
    [k: string]: string;
  };
  /**
   * Optional serialized request body. For JSON APIs this should be a JSON string.
   */
  body?: string;
  /**
   * Optional maximum duration for the host transport attempt in milliseconds.
   */
  timeoutMs?: number;
  [k: string]: unknown;
}
