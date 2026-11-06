import { entryFiles, entryTotalBytes, type CatalogEntry, type CatalogFile } from "./neural-catalog";
import { Sha256 } from "./sha256";

export interface ModelFileWriter {
  write(chunk: Uint8Array): Promise<void>;
  close(): Promise<void>;
  abort(): Promise<void>;
}

/** Where an entry's files live, addressed by package-relative path. */
export interface ModelStorage {
  /** Stored size, or `undefined` when the file is absent. */
  size(path: string): Promise<number | undefined>;
  read(path: string): AsyncIterable<Uint8Array>;
  /** Starts a write that only becomes a file on `close()`. */
  write(path: string): Promise<ModelFileWriter>;
  remove(path: string): Promise<void>;
}

export interface ConsentPrompt {
  entry: CatalogEntry;
  totalBytes: number;
  /** One line per licence the person accepts: the model's, its attribution, and each voice's. */
  licenses: string[];
}

export interface DownloadProgress {
  path: string;
  doneBytes: number;
  totalBytes: number;
}

export interface DownloadOptions {
  fetch: typeof fetch;
  storage: ModelStorage;
  /** The demo proxy's `/assets` URL, for hosts that send no CORS headers (GitHub release assets). */
  assetsUrl: string;
  /** Asked before any request. */
  consent: (prompt: ConsentPrompt) => Promise<boolean>;
  onProgress?: (progress: DownloadProgress) => void;
  /** Aborting stops the request and the stream; the file in flight is removed, verified ones stay. */
  signal?: AbortSignal;
}

export type DownloadResult = { installed: true } | { installed: false; reason: "declined" };

function licenseLines(entry: CatalogEntry): string[] {
  const lines = [
    `${entry.license.spdx ?? "unspecified licence"}${
      entry.license.restrictions !== undefined && entry.license.restrictions !== "none"
        ? `: ${entry.license.restrictions}`
        : ""
    }`
  ];
  if (entry.license.attribution !== undefined) lines.push(entry.license.attribution);
  const seen = new Set<string>();
  for (const voice of entry.voices ?? []) {
    const line = `${String(voice.license["spdx"] ?? "voice licence")}: ${String(
      voice.license["restrictions"] ?? ""
    )}`;
    if (!seen.has(line)) lines.push(line);
    seen.add(line);
  }
  return lines;
}

/** Thrown when `DownloadOptions.signal` aborts a download. */
function cancelled(): Error {
  const error = new Error("download cancelled");
  error.name = "AbortError";
  return error;
}

export function isDownloadCancelled(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function sourceUrl(file: CatalogFile, assetsUrl: string): string {
  const { hostname } = new URL(file.url);
  // GitHub release assets answer without CORS headers, so the browser goes through the demo proxy.
  return hostname === "github.com" ? `${assetsUrl}?url=${encodeURIComponent(file.url)}` : file.url;
}

async function isVerified(storage: ModelStorage, file: CatalogFile): Promise<boolean> {
  if ((await storage.size(file.path)) !== file.bytes) return false;
  const hash = new Sha256();
  for await (const chunk of storage.read(file.path)) hash.update(chunk);
  return hash.digestHex() === file.sha256;
}

function isQuotaError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === "QuotaExceededError" || /quota|no space|storage full/iu.test(error.message))
  );
}

/**
 * Installs every file of an entry (weights and voices) after the person consents; all or nothing
 * per entry in the sense that a failure throws and leaves only verified files behind, so a retry
 * resumes. Each file is streamed to storage and hashed on the way; a size or sha256 mismatch
 * removes the file (`checksum mismatch: <path>`).
 */
export async function downloadEntry(
  entry: CatalogEntry,
  options: DownloadOptions
): Promise<DownloadResult> {
  const totalBytes = entryTotalBytes(entry);
  const accepted = await options.consent({ entry, totalBytes, licenses: licenseLines(entry) });
  if (!accepted) return { installed: false, reason: "declined" };

  let doneBytes = 0;
  for (const file of entryFiles(entry)) {
    if (options.signal?.aborted) throw cancelled();
    if (await isVerified(options.storage, file)) {
      doneBytes += file.bytes;
      options.onProgress?.({ path: file.path, doneBytes, totalBytes });
      continue;
    }
    // A stale or half-written file is never kept.
    await options.storage.remove(file.path);
    await downloadFile(
      file,
      options,
      () => doneBytes,
      (n) => (doneBytes += n),
      totalBytes
    );
  }
  return { installed: true };
}

async function downloadFile(
  file: CatalogFile,
  options: DownloadOptions,
  doneSoFar: () => number,
  advance: (bytes: number) => void,
  totalBytes: number
): Promise<void> {
  let response: Response;
  try {
    response = await options.fetch(
      sourceUrl(file, options.assetsUrl),
      options.signal !== undefined ? { signal: options.signal } : undefined
    );
  } catch (error) {
    if (options.signal?.aborted) throw cancelled();
    throw new Error(`download failed: ${file.path}: ${errorText(error)}`, { cause: error });
  }
  if (!response.ok || response.body === null) {
    const published = new URL(file.url).hostname === "github.com" && response.status === 404;
    throw new Error(
      `${published ? "asset not published yet" : "download failed"} (HTTP ${response.status}): ${file.path}`
    );
  }

  const hash = new Sha256();
  let received = 0;
  let writer: ModelFileWriter;
  try {
    writer = await options.storage.write(file.path);
  } catch (error) {
    throw storageFailure(file, error);
  }
  const reader = response.body.getReader();
  const base = doneSoFar();
  try {
    for (let next = await reader.read(); !next.done; next = await reader.read()) {
      if (options.signal?.aborted) throw cancelled();
      received += next.value.length;
      if (received > file.bytes) break;
      hash.update(next.value);
      try {
        await writer.write(next.value);
      } catch (error) {
        throw storageFailure(file, error);
      }
      options.onProgress?.({ path: file.path, doneBytes: base + received, totalBytes });
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    await writer.abort().catch(() => undefined);
    await options.storage.remove(file.path).catch(() => undefined);
    if (isDownloadCancelled(error) || options.signal?.aborted) throw cancelled();
    if (error instanceof Error && error.message.startsWith("not enough storage")) throw error;
    if (error instanceof Error && error.message.startsWith("could not write")) throw error;
    throw new Error(`download failed: ${file.path}: ${errorText(error)}`, { cause: error });
  }

  if (received !== file.bytes || hash.digestHex() !== file.sha256) {
    await reader.cancel().catch(() => undefined);
    await writer.abort().catch(() => undefined);
    await options.storage.remove(file.path).catch(() => undefined);
    throw new Error(`checksum mismatch: ${file.path}`);
  }
  try {
    await writer.close();
  } catch (error) {
    await options.storage.remove(file.path).catch(() => undefined);
    throw storageFailure(file, error);
  }
  advance(file.bytes);
}

function storageFailure(file: CatalogFile, error: unknown): Error {
  return new Error(
    isQuotaError(error)
      ? `not enough storage space to save ${file.path}; free some browser storage and try again`
      : `could not write ${file.path}: ${errorText(error)}`,
    { cause: error }
  );
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
