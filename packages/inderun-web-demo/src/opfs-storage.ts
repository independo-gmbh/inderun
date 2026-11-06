import type { ModelFileWriter, ModelStorage } from "./neural-downloader";

// The slice of the Origin Private File System the demo uses. The real FileSystemDirectoryHandle
// satisfies it; tests use an in-memory one.

export interface OpfsWritable {
  write(chunk: Uint8Array): Promise<void>;
  close(): Promise<void>;
  abort(): Promise<void>;
}

export interface OpfsFile {
  getFile(): Promise<{
    size: number;
    arrayBuffer(): Promise<ArrayBuffer>;
    stream(): ReadableStream<Uint8Array>;
  }>;
  createWritable(): Promise<OpfsWritable>;
}

export interface OpfsDirectory {
  getDirectoryHandle(name: string, options?: { create?: boolean }): Promise<OpfsDirectory>;
  getFileHandle(name: string, options?: { create?: boolean }): Promise<OpfsFile>;
  removeEntry(name: string, options?: { recursive?: boolean }): Promise<void>;
}

/** The OPFS root, or `undefined` when this browser has none. */
export async function getOpfsRoot(): Promise<OpfsDirectory | undefined> {
  const storage = typeof navigator === "undefined" ? undefined : navigator.storage;
  if (storage === undefined || typeof storage.getDirectory !== "function") return undefined;
  try {
    return (await storage.getDirectory()) as unknown as OpfsDirectory;
  } catch {
    return undefined;
  }
}

/** Walks `a/b/c.bin` to the directory holding it; creates the directories when asked. */
export async function resolveParent(
  root: OpfsDirectory,
  path: string,
  create: boolean
): Promise<{ directory: OpfsDirectory; name: string }> {
  const parts = path.split("/");
  const name = parts.pop()!;
  let directory = root;
  for (const part of parts) directory = await directory.getDirectoryHandle(part, { create });
  return { directory, name };
}

export function isNotFound(error: unknown): boolean {
  return (
    error instanceof Error && (error.name === "NotFoundError" || error.name === "TypeMismatchError")
  );
}

/** Entry files stored under one OPFS directory, addressed by package-relative path. */
export function createOpfsModelStorage(root: OpfsDirectory): ModelStorage {
  return {
    async size(path) {
      try {
        const { directory, name } = await resolveParent(root, path, false);
        return (await (await directory.getFileHandle(name)).getFile()).size;
      } catch (error) {
        if (isNotFound(error)) return undefined;
        throw error;
      }
    },
    async *read(path) {
      const { directory, name } = await resolveParent(root, path, false);
      const reader = (await (await directory.getFileHandle(name)).getFile()).stream().getReader();
      try {
        for (let next = await reader.read(); !next.done; next = await reader.read()) {
          yield next.value;
        }
      } finally {
        reader.releaseLock();
      }
    },
    async write(path): Promise<ModelFileWriter> {
      const { directory, name } = await resolveParent(root, path, true);
      return (await directory.getFileHandle(name, { create: true })).createWritable();
    },
    async remove(path) {
      try {
        const { directory, name } = await resolveParent(root, path, false);
        await directory.removeEntry(name);
      } catch (error) {
        if (!isNotFound(error)) throw error;
      }
    }
  };
}
