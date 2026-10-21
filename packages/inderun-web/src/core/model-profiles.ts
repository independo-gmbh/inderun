import type { SharedPlannerInput } from "./route-planner.js";

/**
 * The built-in profile: every registered target, ranked by constraints and
 * preferences alone. Requests that name no profile route within it.
 */
export const AUTO_MODEL_PROFILE = "auto";

/**
 * Application-defined model profiles: a profile name mapped to an ordered list of
 * target ids (provider instance ids, each bound to one model). Requests name a
 * profile through `TaskRequest.modelProfile`; the route planner treats the list as
 * an allow-list and ranks its entries after placement and before preferences.
 * Ids that name no registered provider are ignored by the planner.
 */
export type ModelProfiles = Readonly<Record<string, readonly string[]>>;

/** A resolved profile as the shared planner consumes it; absent means `auto`. */
export type ResolvedModelProfile = SharedPlannerInput["modelProfile"];

/**
 * Checks profile configuration once, when the engine is constructed, so a
 * malformed profile is a setup error rather than a per-request surprise.
 * @throws {Error} When a profile is named `auto`, is empty, or lists a target twice.
 */
export function validateModelProfiles(profiles: ModelProfiles): void {
  for (const [name, targetIds] of Object.entries(profiles)) {
    if (name.length === 0) {
      throw new Error("Model profile names must be non-empty.");
    }
    if (name === AUTO_MODEL_PROFILE) {
      throw new Error(
        `"${AUTO_MODEL_PROFILE}" is the built-in model profile and cannot be redefined.`
      );
    }
    if (targetIds.length === 0) {
      throw new Error(`Model profile "${name}" must list at least one target id.`);
    }
    const seen = new Set<string>();
    for (const id of targetIds) {
      if (id.length === 0) {
        throw new Error(`Model profile "${name}" lists an empty target id.`);
      }
      if (seen.has(id)) {
        throw new Error(`Model profile "${name}" lists target "${id}" more than once.`);
      }
      seen.add(id);
    }
  }
}

/**
 * Resolves a request's profile name against the configured profiles.
 * @returns `{ known: true }` with the planner input (undefined for `auto`), or
 *   `{ known: false }` when the name matches no configured profile.
 */
export function resolveModelProfile(
  profiles: ModelProfiles,
  name: string | undefined
): { known: true; profile: ResolvedModelProfile } | { known: false } {
  if (name === undefined || name === AUTO_MODEL_PROFILE) {
    return { known: true, profile: undefined };
  }
  if (!Object.hasOwn(profiles, name)) {
    return { known: false };
  }
  // validateModelProfiles guarantees every configured profile is non-empty.
  const [first, ...rest] = profiles[name]!;
  return { known: true, profile: { name, targetIds: [first!, ...rest] } };
}
