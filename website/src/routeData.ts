/**
 * Route middleware for every Starlight page: the page's JSON-LD (`WebPage` + `BreadcrumbList`),
 * a description for generated API pages that have none, and `noindex` for preview builds and the
 * 404 page. The robots tag lives here, not in astro.config.mjs, so a page never carries two.
 */
import { defineRouteMiddleware } from "@astrojs/starlight/route-data";
import { getCollection } from "astro:content";
import versions from "../versions.json";
import { IDS, absoluteUrl } from "./seo";

type HeadEntry = {
  tag: string;
  attrs?: Record<string, string | boolean | undefined>;
  content?: string;
};

const isPreview = process.env.SITE_ENV === "preview";

const API_PACKAGES: { prefix: string; name: string; version: string }[] = [
  {
    prefix: "docs/api/typescript/capacitor",
    name: versions.capacitorPlugin.package,
    version: versions.capacitorPlugin.version
  },
  {
    prefix: "docs/api/typescript/web",
    name: "@independo/inderun-web",
    version: versions.packages["@independo/inderun-web"]
  }
];

let titlesById: Promise<Map<string, string>> | undefined;
function docTitles() {
  titlesById ??= getCollection("docs").then(
    (entries) => new Map(entries.map((entry) => [entry.id, entry.data.title]))
  );
  return titlesById;
}

function setMeta(head: HeadEntry[], key: "name" | "property", value: string, content: string) {
  const existing = head.find((entry) => entry.tag === "meta" && entry.attrs?.[key] === value);
  if (existing) existing.attrs = { ...existing.attrs, content };
  else head.push({ tag: "meta", attrs: { [key]: value, content } });
}

export const onRequest = defineRouteMiddleware(async (context) => {
  const route = context.locals.starlightRoute;
  const { entry, head } = route;
  const id = entry.id;
  const is404 = id === "404";

  // Generated TypeDoc pages carry no description; derive one so no two pages share the site default.
  const api = API_PACKAGES.find(({ prefix }) => id === prefix || id.startsWith(`${prefix}/`));
  if (api && !entry.data.description) {
    const description = `API reference for ${entry.data.title} in ${api.name} ${api.version}.`;
    entry.data.description = description;
    setMeta(head, "name", "description", description);
    setMeta(head, "property", "og:description", description);
  }

  head.push({
    tag: "meta",
    attrs: {
      name: "robots",
      content: isPreview ? "noindex, nofollow" : is404 ? "noindex" : "max-image-preview:large"
    }
  });
  if (is404) return;

  const path = context.url.pathname.replace(/\/$/, "") || "/";
  const url = absoluteUrl(path);
  const titles = await docTitles();

  // Home, then every ancestor path that is itself a docs page, then this page.
  const crumbs: { name: string; item?: string }[] = [{ name: "Home", item: absoluteUrl("/") }];
  const segments = path.split("/").filter(Boolean);
  for (let i = 1; i < segments.length; i++) {
    const ancestor = segments.slice(0, i).join("/");
    const title = titles.get(ancestor);
    if (title)
      crumbs.push({
        name: ancestor === "docs" ? "Docs" : title,
        item: absoluteUrl(`/${ancestor}`)
      });
  }
  crumbs.push({ name: entry.data.title, item: url });

  const graph = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebPage",
        "@id": `${url}#webpage`,
        url,
        name: entry.data.title,
        ...(entry.data.description ? { description: entry.data.description } : {}),
        inLanguage: "en",
        isPartOf: { "@id": IDS.website },
        about: { "@id": IDS.software }
      },
      {
        "@type": "BreadcrumbList",
        "@id": `${url}#breadcrumb`,
        itemListElement: crumbs.map((crumb, index) => ({
          "@type": "ListItem",
          position: index + 1,
          name: crumb.name,
          item: crumb.item
        }))
      }
    ]
  };
  head.push({
    tag: "script",
    attrs: { type: "application/ld+json" },
    content: JSON.stringify(graph)
  });
});
