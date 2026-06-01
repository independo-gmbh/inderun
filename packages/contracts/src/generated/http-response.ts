/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Normalized HTTP response payload returned by host-provided cloud transport.
 */
export type HttpResponse = {
    /**
     * Serialized response body returned by the provider transport.
     */
    body: string;
    /**
     * HTTP response headers normalized to string key-value pairs.
     */
    headers: { [key: string]: string };
    /**
     * HTTP status code returned by the provider transport.
     */
    status: number;
    /**
     * HTTP status text returned by the provider transport.
     */
    statusText: string;
    [property: string]: unknown;
}
