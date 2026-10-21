import type { TextExecutionOptions, TextGenerationOptions } from "@independo/inderun-web";
import { DEFAULT_ONNX_WEB_PROVIDER_ID } from "@independo/inderun-web/onnx";
import { DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID } from "@independo/inderun-web/system-model";

/**
 * The text-simplification feature this demo is built around: the instruction, the model
 * profile it routes within, and the one facade call shape both delivery modes share.
 */

/** Canonical privacy values, as the facade's `execution.privacy` takes them. */
export type Privacy = NonNullable<TextExecutionOptions["privacy"]>;

/** The application-defined model profile the simplification feature routes within. */
export const SIMPLIFY_PROFILE = "simplify";

export const SYSTEM_MODEL_TARGET_ID = DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID;
export const ONNX_TARGET_ID = DEFAULT_ONNX_WEB_PROVIDER_ID;

/** Factory-registered OpenAI-compatible targets are named `openai:<model>`. */
export function cloudTargetId(model: string): string {
  return `openai:${model}`;
}

/**
 * The profile's targets, in the order the app prefers them: the browser's built-in model,
 * then the bundled ONNX model, then the cloud model behind the demo proxy. Privacy still
 * decides which of them a given request may use.
 */
export function simplifyProfileTargets(cloudModel: string): string[] {
  return [SYSTEM_MODEL_TARGET_ID, ONNX_TARGET_ID, cloudTargetId(cloudModel)];
}

export function isOnDeviceTarget(targetId: string): boolean {
  return targetId === SYSTEM_MODEL_TARGET_ID || targetId === ONNX_TARGET_ID;
}

export const PLAIN_LANGUAGE_INSTRUCTION = [
  "Rewrite the user's text in plain language.",
  "Use short sentences and everyday words, and explain any term the reader must know.",
  "Keep every fact, date, amount, deadline and obligation. Do not add advice or information that is not in the text.",
  "Reply with the rewritten text only."
].join(" ");

export const SAMPLE_TEXT =
  "Pursuant to the applicable provisions of the tenancy agreement, the lessee is hereby notified that, " +
  "in the event that the outstanding balance in respect of service charges for the preceding accounting " +
  "period is not remitted in full within fourteen (14) days of receipt of this notice, the lessor reserves " +
  "the right to initiate recovery proceedings, the costs of which shall be borne by the lessee, without " +
  "prejudice to any further claims arising under the agreement.";

/** The one options object both `generateText()` and `streamText()` receive. */
export function simplifyOptions(text: string, privacy: Privacy): TextGenerationOptions {
  return {
    model: SIMPLIFY_PROFILE,
    system: PLAIN_LANGUAGE_INSTRUCTION,
    prompt: text,
    execution: { privacy }
  };
}
