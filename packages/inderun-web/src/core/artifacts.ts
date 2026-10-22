import type { ArtifactReadRequest, MediaArtifact } from "@independo/inderun-contracts";
import { createInternal, createUnavailable } from "./errors.js";

/**
 * Size limits of an engine's artifact store (ADR 017). Every limit is in bytes.
 */
export interface ArtifactLimits {
  /** Largest single artifact a provider may write. Default 16 MiB. */
  maxArtifactBytes?: number;
  /** Most bytes the store holds across all undisposed artifacts. Default 64 MiB. */
  maxStoreBytes?: number;
  /** Most bytes one `readArtifact` call returns. Default 1 MiB. */
  maxReadBytes?: number;
}

export const DEFAULT_ARTIFACT_LIMITS: Required<ArtifactLimits> = {
  maxArtifactBytes: 16 * 1024 * 1024,
  maxStoreBytes: 64 * 1024 * 1024,
  maxReadBytes: 1024 * 1024
};

/**
 * One range of an artifact's bytes, as `IndeRun.readArtifact` returns it.
 */
export interface ArtifactChunk {
  /** The artifact the bytes belong to. */
  artifactId: string;
  /** Byte offset of `bytes` within the artifact. */
  offset: number;
  /** The bytes of this range; empty when `offset` is the artifact's end. */
  bytes: Uint8Array;
  /** Size of the whole artifact in bytes. */
  totalBytes: number;
  /** Whether this range reaches the end of the artifact. */
  done: boolean;
}

/** What a provider declares when it starts writing an artifact. */
export interface ArtifactSpec {
  /** IANA media type of the bytes, e.g. `audio/wav`; parameters ride on it. */
  mediaType: string;
  /** Duration of time-based media in milliseconds, where the provider knows it. */
  durationMs?: number;
}

/**
 * Writes one artifact into the engine's store. `finish()` hands it over: it commits the run
 * to the provider and returns the reference the provider puts in its output. A provider that
 * fails or stops before `finish()` calls `abort()`; the engine also discards any writer an
 * attempt left open.
 */
export interface ArtifactWriter {
  /**
   * Appends bytes. Throws `Unavailable` (`details.code: "artifact_too_large"`) once the
   * artifact would exceed the engine's per-artifact limit; the attempt has not committed, so
   * the run may fall back.
   */
  write(bytes: Uint8Array): void;
  /**
   * Hands the finished artifact to the engine and commits the run. Throws `Unavailable`
   * (`artifact_store_full`) when the store has no room, and `Unavailable`
   * (`run_not_active`) when the run was cancelled or has ended -- in both cases before
   * committing.
   */
  finish(): MediaArtifact;
  /** Discards everything written. Idempotent. */
  abort(): void;
}

/** Where a provider creates artifacts: `RunContext.artifacts`. */
export interface ArtifactSink {
  create(spec: ArtifactSpec): ArtifactWriter;
}

interface StoredArtifact {
  reference: MediaArtifact;
  bytes: Uint8Array;
}

/**
 * The engine-owned, in-memory artifact store (ADR 017): one per `IndeRun` instance. It holds
 * every finished artifact until the application disposes it; there are no temporary files,
 * so nothing outlives the process. Reads are ranged and bounded by `maxReadBytes`.
 */
export class ArtifactStore {
  private readonly limits: Required<ArtifactLimits>;
  private readonly artifacts = new Map<string, StoredArtifact>();
  private storedBytes = 0;

  constructor(limits: ArtifactLimits = {}) {
    this.limits = { ...DEFAULT_ARTIFACT_LIMITS, ...limits };
  }

  /**
   * Opens the artifacts of one attempt. `commit` is the attempt's commit hook; a writer's
   * `finish()` calls it, and refuses the handoff when it returns `false`.
   */
  attempt(commit: () => boolean): AttemptArtifacts {
    return new AttemptArtifacts(this, commit);
  }

  /** Reads one range. See `IndeRunApi.readArtifact` for the contract. */
  read(request: ArtifactReadRequest): ArtifactChunk {
    const stored = this.artifacts.get(request.artifactId);
    if (stored === undefined) {
      throw createUnavailable(`Artifact '${request.artifactId}' is not held by this engine.`, {
        retryable: false,
        details: { code: "artifact_not_found" }
      });
    }
    const totalBytes = stored.bytes.byteLength;
    const offset = request.offset ?? 0;
    if (offset > totalBytes) {
      const validationIssues = [
        {
          path: "/offset",
          message: `offset ${offset} is beyond the artifact's ${totalBytes} bytes`
        }
      ];
      throw createInternal(
        `Validation failed for ArtifactReadRequest: /offset - ${validationIssues[0]!.message}`,
        { details: { validationIssues } }
      );
    }
    const length = Math.min(request.maxBytes ?? this.limits.maxReadBytes, this.limits.maxReadBytes);
    const end = Math.min(offset + length, totalBytes);
    return {
      artifactId: request.artifactId,
      offset,
      // A copy: the caller may keep or mutate it without touching the stored bytes.
      bytes: stored.bytes.slice(offset, end),
      totalBytes,
      done: end === totalBytes
    };
  }

  /** Releases an artifact's bytes. Idempotent; unknown ids are ignored. */
  dispose(artifactId: string): void {
    const stored = this.artifacts.get(artifactId);
    if (stored === undefined) return;
    this.artifacts.delete(artifactId);
    this.storedBytes -= stored.bytes.byteLength;
  }

  /** The stored reference for `artifactId`, or `undefined` once it was disposed. */
  reference(artifactId: string): MediaArtifact | undefined {
    return this.artifacts.get(artifactId)?.reference;
  }

  /** @internal Registers a finished artifact. */
  store(spec: ArtifactSpec, bytes: Uint8Array): MediaArtifact {
    if (this.storedBytes + bytes.byteLength > this.limits.maxStoreBytes) {
      throw createUnavailable(
        "The engine's artifact store is full; dispose artifacts to free it.",
        {
          details: { code: "artifact_store_full" }
        }
      );
    }
    const reference: MediaArtifact = {
      id: `art_${randomId()}`,
      mediaType: spec.mediaType,
      owner: "engine",
      lifetime: "until_disposed",
      byteLength: bytes.byteLength,
      ...(spec.durationMs !== undefined ? { durationMs: spec.durationMs } : {})
    };
    this.artifacts.set(reference.id, { reference, bytes });
    this.storedBytes += bytes.byteLength;
    return reference;
  }

  /** @internal */
  get maxArtifactBytes(): number {
    return this.limits.maxArtifactBytes;
  }
}

/**
 * The artifacts one attempt created. The engine keeps the one the attempt returned and
 * releases the rest: everything from an attempt that failed, was cancelled or lost to
 * fallback, and anything a winning attempt finished but did not return. A returned artifact
 * is never released behind the application's back.
 */
export class AttemptArtifacts implements ArtifactSink {
  private readonly finished = new Set<string>();
  private readonly open = new Set<ArtifactWriter>();
  private released = false;

  constructor(
    private readonly store: ArtifactStore,
    private readonly commit: () => boolean
  ) {}

  create(spec: ArtifactSpec): ArtifactWriter {
    const chunks: Uint8Array[] = [];
    let size = 0;
    let closed = false;
    const writer: ArtifactWriter = {
      write: (bytes) => {
        if (closed) throw createInternal("The artifact writer is already closed.");
        if (size + bytes.byteLength > this.store.maxArtifactBytes) {
          writer.abort();
          throw createUnavailable(
            `The artifact exceeds the engine's ${this.store.maxArtifactBytes}-byte limit.`,
            { details: { code: "artifact_too_large" } }
          );
        }
        chunks.push(bytes.slice());
        size += bytes.byteLength;
      },
      finish: () => {
        if (closed) throw createInternal("The artifact writer is already closed.");
        const bytes = concat(chunks, size);
        writer.abort();
        // A provider that keeps working after its attempt ended (a late callback, say) must
        // not leave an artifact behind that nobody owns.
        if (this.released) {
          throw createUnavailable("The attempt has ended; the artifact was discarded.", {
            details: { code: "run_not_active" }
          });
        }
        // Stored before the commit so a full store fails the attempt pre-commit; dropped
        // again when the run refuses the commit.
        const reference = this.store.store(spec, bytes);
        if (!this.commit()) {
          this.store.dispose(reference.id);
          throw createUnavailable("The run is no longer active; the artifact was discarded.", {
            details: { code: "run_not_active" }
          });
        }
        this.finished.add(reference.id);
        return reference;
      },
      abort: () => {
        closed = true;
        chunks.length = 0;
        this.open.delete(writer);
      }
    };
    this.open.add(writer);
    return writer;
  }

  /** Whether `artifactId` was finished by this attempt and is still held. */
  owns(artifactId: string): boolean {
    return this.finished.has(artifactId) && this.store.reference(artifactId) !== undefined;
  }

  /** Releases every artifact of this attempt except `keep`, and closes open writers. */
  release(keep?: string): void {
    this.released = true;
    for (const writer of [...this.open]) writer.abort();
    for (const id of this.finished) {
      if (id !== keep) this.store.dispose(id);
    }
    this.finished.clear();
  }
}

function concat(chunks: Uint8Array[], size: number): Uint8Array {
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function randomId(): string {
  const random = new Uint8Array(12);
  globalThis.crypto.getRandomValues(random);
  return Array.from(random, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
