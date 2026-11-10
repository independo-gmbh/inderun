import {
  NeuralSpeechRuntimeError,
  type SpeechPackageFiles
} from "@independo/inderun-web/neural-speech";
import { isNotFound, resolveParent, type OpfsDirectory } from "./opfs-storage";

/**
 * Same rule as the SDK's `checkPackageFileName` (which the SDK does not export): refuses empty,
 * absolute and URL-like names and any `..` component, written or percent-encoded.
 */
export function checkPackageFileName(file: string): void {
  const decode = (part: string): string => {
    try {
      return decodeURIComponent(part);
    } catch {
      return part;
    }
  };
  if (
    file.length === 0 ||
    /^[/\\]/u.test(file) ||
    /^[a-z][a-z0-9+.-]*:/iu.test(file) ||
    file.split(/[/\\]/u).some((part) => {
      const decoded = decode(part);
      return part === ".." || decoded === ".." || /[/\\]/u.test(decoded);
    })
  ) {
    throw new NeuralSpeechRuntimeError("capability", `model file name invalid: ${file}`);
  }
}

/** Serves a package's files from an OPFS directory to the neural speech runtime. */
export function createOpfsPackageFiles(root: OpfsDirectory): SpeechPackageFiles {
  return {
    async read(file) {
      checkPackageFileName(file);
      try {
        const { directory, name } = await resolveParent(root, file, false);
        const handle = await directory.getFileHandle(name);
        return new Uint8Array(await (await handle.getFile()).arrayBuffer());
      } catch (error) {
        if (isNotFound(error)) {
          throw new NeuralSpeechRuntimeError("capability", `model files missing: ${file}`, error);
        }
        throw error;
      }
    }
  };
}
