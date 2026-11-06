import { createIndeRunWeb, type IndeRunApi } from "@independo/inderun-web";
import {
  createOnnxNeuralSpeechRuntime,
  type OnnxRuntimeWebModule
} from "@independo/inderun-web/neural-speech";
import { DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID } from "@independo/inderun-web/system-speech";
import { labProfileName, neuralProviderId, type InstalledModel } from "./neural-catalog";

/**
 * The lab's own engine: the browser's system speech plus one neural provider per installed entry,
 * and per entry the profile `voices-lab:<entry id>` = [neural provider, system speech]. It is built
 * only after the lab is switched on and a model is installed, so the demo's main engine never
 * changes. Rebuilt after each install, because an engine registers its providers once. The SDK
 * offers no public close for an engine or for the ONNX runtime it creates (`close` exists only on
 * a graph executor, which `createOnnxNeuralSpeechRuntime` keeps private), so the caller drops its
 * reference to the replaced engine and lets it be collected; sessions are not released explicitly.
 */
export function createVoicesLabEngine(
  installed: InstalledModel[],
  load?: () => Promise<OnnxRuntimeWebModule>
): IndeRunApi {
  const runtimes = installed.map((model) =>
    createOnnxNeuralSpeechRuntime({
      files: model.files,
      ...(load === undefined ? {} : { load })
    })
  );
  const engine = createIndeRunWeb({
    systemSpeech: {},
    neuralSpeech: installed.map((model, index) => ({
      modelPackage: model.modelPackage,
      runtime: runtimes[index]!
    })),
    modelProfiles: Object.fromEntries(
      installed.map((model) => [
        labProfileName(model.entry.id),
        [neuralProviderId(model.entry.id), DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID]
      ])
    )
  });
  return engine;
}
