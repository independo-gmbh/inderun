import type { OnnxRuntimeWebModule } from "@independo/inderun-web/neural-speech";
import type { IndeRunApi } from "@independo/inderun-web";
import catalogJson from "../../../contracts/fixtures/speech/neural-model-catalog.json";
import corpusJson from "../../../contracts/fixtures/speech/utterance-corpus.json";
import { getDemoAssetsUrl } from "./config";
import { entryRef, type CatalogEntry, type NeuralCatalog } from "./neural-catalog";
import { createOpfsPackageFiles } from "./opfs-package-files";
import {
  createOpfsModelStorage,
  getOpfsRoot,
  isNotFound,
  resolveParent,
  type OpfsDirectory
} from "./opfs-storage";
import { createVoicesLabEngine } from "./voices-lab-engine";
import { mountVoicesLabPanel, type EntryStore, type VoicesLabCorpus } from "./voices-lab-panel";

let persistRequested = false;

/** Asks the browser not to evict the models; best effort, a refusal changes nothing. */
async function requestPersistentStorage(): Promise<void> {
  if (persistRequested) return;
  persistRequested = true;
  try {
    await navigator.storage.persist?.();
  } catch {
    // Not granted; the models still download, the browser may evict them under pressure.
  }
}

/** Loaded only when the lab is switched on (`VITE_INDERUN_VOICES_LAB=1`): see main.ts. */
export async function startVoicesLab(root: HTMLElement, inderun: IndeRunApi): Promise<void> {
  const opfs = await getOpfsRoot();
  const openEntryStore =
    opfs === undefined
      ? undefined
      : async (entry: CatalogEntry, mode: { create: boolean }): Promise<EntryStore | undefined> => {
          const ref = entryRef(entry);
          let directory: OpfsDirectory;
          try {
            ({ directory } = await resolveParent(opfs, `${ref}/x`, mode.create));
          } catch (error) {
            if (!mode.create && isNotFound(error)) return undefined;
            throw error;
          }
          return {
            ref,
            storage: createOpfsModelStorage(directory),
            files: createOpfsPackageFiles(directory)
          };
        };
  await mountVoicesLabPanel(root, inderun, {
    enabled: true,
    catalog: catalogJson as unknown as NeuralCatalog,
    corpus: corpusJson as unknown as VoicesLabCorpus,
    assetsUrl: getDemoAssetsUrl(),
    fetch: (input, init) => fetch(input, init),
    ...(openEntryStore === undefined ? {} : { openEntryStore }),
    requestPersistence: requestPersistentStorage,
    createEngine: (installed) =>
      createVoicesLabEngine(
        installed,
        () => import("onnxruntime-web") as unknown as Promise<OnnxRuntimeWebModule>
      )
  });
}
