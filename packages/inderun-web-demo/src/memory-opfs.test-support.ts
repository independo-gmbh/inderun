import type { OpfsDirectory, OpfsFile } from "./opfs-storage";

/** An in-memory stand-in for the Origin Private File System: writes commit on close, like the real one. */
export class MemoryDirectory implements OpfsDirectory {
  readonly files = new Map<string, Uint8Array>();
  readonly dirs = new Map<string, MemoryDirectory>();
  /** Set to make the next `createWritable().write` throw this. */
  failWrite: Error | undefined;

  async getDirectoryHandle(name: string, options?: { create?: boolean }): Promise<OpfsDirectory> {
    let dir = this.dirs.get(name);
    if (dir === undefined) {
      if (options?.create !== true) throw notFound(name);
      dir = new MemoryDirectory();
      this.dirs.set(name, dir);
    }
    return dir;
  }

  async getFileHandle(name: string, options?: { create?: boolean }): Promise<OpfsFile> {
    if (!this.files.has(name)) {
      if (options?.create !== true) throw notFound(name);
      this.files.set(name, new Uint8Array());
    }
    const files = this.files;
    const fail = () => this.failWrite;
    return {
      async getFile() {
        const bytes = files.get(name) ?? new Uint8Array();
        return new File([bytes as BlobPart], name);
      },
      async createWritable() {
        const parts: Uint8Array[] = [];
        return {
          async write(chunk: Uint8Array) {
            const failure = fail();
            if (failure !== undefined) throw failure;
            parts.push(chunk.slice());
          },
          async close() {
            const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
            let at = 0;
            for (const p of parts) {
              all.set(p, at);
              at += p.length;
            }
            files.set(name, all);
          },
          async abort() {
            parts.length = 0;
          }
        };
      }
    };
  }

  async removeEntry(name: string): Promise<void> {
    if (!this.files.delete(name) && !this.dirs.delete(name)) throw notFound(name);
  }
}

function notFound(name: string): Error {
  const error = new Error(`not found: ${name}`);
  error.name = "NotFoundError";
  return error;
}
