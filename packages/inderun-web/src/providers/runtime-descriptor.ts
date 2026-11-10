/**
 * Shared helpers for selecting a provider runtime from JSON-serializable configuration.
 *
 * A runtime descriptor is a plain object with a string `kind`; the provider turns it into a
 * runtime by calling the matching factory. This lets a bridge that marshals `configure(options)`
 * as JSON reach the built-in and fixture runtimes without passing a function across the hop.
 */

/**
 * Whether `value` is a runtime descriptor (an object with a string `kind`) rather than a runtime
 * implementation.
 */
export function isRuntimeDescriptor(value: object | null | undefined): value is { kind: string } {
  return (
    value !== null && value !== undefined && typeof (value as { kind?: unknown }).kind === "string"
  );
}

/**
 * Throws a `TypeError` naming the field and the accepted kinds when `kind` is not one of `known`.
 */
export function assertKnownKind(field: string, kind: unknown, known: readonly string[]): void {
  if (typeof kind !== "string" || !known.includes(kind)) {
    throw new TypeError(
      `${field}: unknown runtime kind "${String(kind)}"; expected one of ${known.join(", ")}`
    );
  }
}
