import { defineMiddleware } from "astro:middleware";

/**
 * Every link that leaves inderun.dev opens in a new tab. Rewriting the rendered HTML here covers
 * the Astro pages, the Markdown docs, the generated API reference and Starlight's own components
 * (sidebar, social icons, edit link) in one place, so a new link can't miss the rule.
 *
 * Only absolute http(s) links to another host are touched. A link that already sets `target` is
 * left alone; an existing `rel` keeps its values and gains `noopener`. Screen readers hear
 * "(opens in new tab)": appended to `aria-label` when the link has one, otherwise as visually
 * hidden text at the end of the link.
 */
const SITE_HOST = "inderun.dev";
const ANCHOR = /(<a\b[^>]*>)([\s\S]*?<\/a>)/gi;
const HREF = /\shref="(https?:\/\/[^"]*)"/i;
const REL = /\srel="([^"]*)"/i;
const ARIA_LABEL = /\saria-label="([^"]*)"/i;
const NEW_TAB = "(opens in new tab)";

function isExternal(href: string): boolean {
  try {
    return new URL(href).hostname !== SITE_HOST;
  } catch {
    return false;
  }
}

export function openExternalLinksInNewTab(html: string): string {
  return html.replace(ANCHOR, (element, tag: string, rest: string) => {
    const href = HREF.exec(tag)?.[1];
    if (!href || !isExternal(href) || /\starget=/i.test(tag)) return element;
    const rel = REL.exec(tag);
    let open = rel
      ? tag.replace(
          REL,
          ` rel="${[...new Set([...rel[1].split(/\s+/).filter(Boolean), "noopener"])].join(" ")}"`
        )
      : tag.replace(/>$/, ' rel="noopener">');
    open = open.replace(/>$/, ' target="_blank">');
    const label = ARIA_LABEL.exec(open);
    if (label) {
      return open.replace(ARIA_LABEL, ` aria-label="${label[1]} ${NEW_TAB}"`) + rest;
    }
    return open + rest.replace(/<\/a>$/i, `<span class="sr-only"> ${NEW_TAB}</span></a>`);
  });
}

export const onRequest = defineMiddleware(async (_context, next) => {
  const response = await next();
  if (!response.headers.get("content-type")?.includes("text/html")) return response;
  const html = await response.text();
  return new Response(openExternalLinksInNewTab(html), {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers
  });
});
