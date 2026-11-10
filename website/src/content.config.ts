import { defineCollection } from "astro:content";
import { z } from "astro/zod";
import { glob } from "astro/loaders";
import { docsSchema } from "@astrojs/starlight/schema";
import { PUBLISHED_GLOBS } from "../docs-architecture.mjs";

/**
 * Published docs are read straight from the repository's docs/ folder, so GitHub and the site
 * render the same file. `slug` is required and becomes the entry id, which makes the URL
 * independent of where the file sits. Generated TypeDoc pages under src/content/docs have no
 * slug and get a lowercase id from their path. src/404.md is Starlight's 404 page (slug "404").
 */
export const collections = {
  docs: defineCollection({
    loader: glob({
      base: "..",
      pattern: [...PUBLISHED_GLOBS, "website/src/404.md"],
      generateId: ({ entry, data }) => {
        if (typeof data.slug === "string") return data.slug;
        return entry
          .replace(/^website\/src\/content\/docs\//, "")
          .replace(/\.md$/, "")
          .replace(/(^|\/)index$/, "")
          .split("/")
          .map((segment) => segment.toLowerCase())
          .join("/");
      }
    }),
    // `description` is required for every docs/ page by scripts/check-docs-architecture.mjs;
    // generated TypeDoc pages get one from src/routeData.ts.
    schema: docsSchema({
      extend: z.object({
        description: z.string().min(1).max(155).optional()
      })
    })
  })
};
