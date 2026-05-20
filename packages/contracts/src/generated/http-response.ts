/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Normalized HTTP response payload returned by host-provided cloud transport.
 */
export interface HttpResponse {
  /**
   * HTTP status code returned by the provider transport.
   */
  status: number;
  /**
   * HTTP status text returned by the provider transport.
   */
  statusText: string;
  /**
   * HTTP response headers normalized to string key-value pairs.
   */
  headers: {
    [k: string]: string;
  };
  /**
   * Serialized response body returned by the provider transport.
   */
  body: string;
  [k: string]: unknown;
}
