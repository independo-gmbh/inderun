import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { parseDocsPaths } from "../../published-urls.mjs";
import publishedUrls from "../../published-urls.txt?raw";
import { IMPRINT, LANDING, NOTICES, PRIVACY, SOFTWARE_DESCRIPTION, absoluteUrl } from "../seo";

/** llms.txt: the landing page and the published docs destinations only; no internal docs, no generated API pages. */
export const GET: APIRoute = async () => {
  const docs = new Map<string, { title: string; description?: string }>(
    (await getCollection("docs")).map((entry) => [`/${entry.id}`, entry.data])
  );
  const lines = [
    "# IndeRun",
    "",
    `> ${SOFTWARE_DESCRIPTION}`,
    "",
    "## Start",
    "",
    `- [${LANDING.title}](${absoluteUrl("/")}): ${LANDING.description}`
  ];
  for (const path of parseDocsPaths(publishedUrls)) {
    const data = docs.get(path);
    if (!data) throw new Error(`published-urls.txt lists ${path}, which is not a docs page`);
    lines.push(
      `- [${data.title}](${absoluteUrl(path)})${data.description ? `: ${data.description}` : ""}`
    );
  }
  lines.push(
    "",
    "## Optional",
    "",
    `- [${IMPRINT.title}](${absoluteUrl("/imprint")}): ${IMPRINT.description}`,
    `- [${PRIVACY.title}](${absoluteUrl("/privacy")}): ${PRIVACY.description}`,
    `- [${NOTICES.title}](${absoluteUrl("/notices")}): ${NOTICES.description}`,
    ""
  );
  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/plain; charset=utf-8" }
  });
};
