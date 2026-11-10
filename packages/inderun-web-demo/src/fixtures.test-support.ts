import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { NeuralCatalog } from "./neural-catalog";

// vitest runs from the package directory (pnpm --filter), so the repository root is two levels up.
export function loadFixture<T>(name: string): T {
  return JSON.parse(
    readFileSync(resolve(process.cwd(), "../../contracts/fixtures/speech", name), "utf8")
  ) as T;
}

export const catalog = (): NeuralCatalog => loadFixture<NeuralCatalog>("neural-model-catalog.json");
