import type { APIRoute } from "astro";
import { SITE } from "../../docs-architecture.mjs";
import { isPreview } from "../site";

export const GET: APIRoute = () =>
  new Response(
    isPreview
      ? "User-agent: *\nDisallow: /\n"
      : `User-agent: *\nAllow: /\n\nSitemap: ${SITE}/sitemap-index.xml\n`,
    { headers: { "Content-Type": "text/plain; charset=utf-8" } }
  );
