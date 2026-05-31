/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Normalized HTTP request payload for host-provided cloud transport.
 */
export type HttpRequest = {
    /**
     * Optional serialized request body. For JSON APIs this should be a JSON string.
     */
    body?: string;
    /**
     * HTTP headers to send after the provider adapter has applied any required transport-level
     * credentials.
     */
    headers?: { [key: string]: string };
    /**
     * HTTP method to use for the request.
     */
    method: Method;
    /**
     * Optional maximum duration for the host transport attempt in milliseconds.
     */
    timeoutMs?: number;
    /**
     * Absolute target URL for the provider transport request.
     */
    url: string;
    [property: string]: unknown;
}

/**
 * HTTP method to use for the request.
 */
export type Method = "GET" | "POST" | "PUT" | "DELETE" | "PATCH";
