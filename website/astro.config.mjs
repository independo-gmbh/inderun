import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";
import starlight from "@astrojs/starlight";
import starlightLinksValidator from "starlight-links-validator";
import { createStarlightTypeDocPlugin } from "starlight-typedoc";
import remarkRepoLinks from "./plugins/remark-repo-links.mjs";
import remarkGithubAlerts from "./plugins/remark-github-alerts.mjs";
import { sitemapLastmod } from "./plugins/sitemap-lastmod.mjs";
import { REPOSITORY, SITE, pinnedRepoUrl, readVersions } from "./docs-architecture.mjs";
import { findApiReferencePaths, isApiReferencePath, readSitemapPaths } from "./published-urls.mjs";
import { enamelCodeTheme } from "./src/styles/code-theme.mjs";
import { THEME_COLORS, themeColorScript } from "./src/theme-color.mjs";

const versions = readVersions();

const [capacitorTypeDoc, capacitorTypeDocSidebar] = createStarlightTypeDocPlugin();
const [webTypeDoc, webTypeDocSidebar] = createStarlightTypeDocPlugin();

/** Reference is generated from the published .d.ts of the exact versions in versions.json. */
const typeDocOptions = {
  excludePrivate: true,
  excludeInternal: true,
  readme: "none",
  skipErrorChecking: true,
  entryFileName: "index",
  disableSources: true
};

const stripSlash = (url) => url.replace(/\/$/, "");
const sitemapPaths = readSitemapPaths();
const sitemapUrls = new Set(sitemapPaths.map((p) => stripSlash(`${SITE}${p}`)));
const lastmod = sitemapLastmod({
  site: SITE,
  paths: sitemapPaths,
  discover: findApiReferencePaths
});
const isDocsUrl = (url) => /^\/docs(\/|$)/.test(new URL(url).pathname);
const isApiReferenceUrl = (url) => isApiReferencePath(stripSlash(new URL(url).pathname));

const external = (label, href) => ({
  label,
  link: href,
  attrs: { class: "sl-external", rel: "noopener" }
});

export default defineConfig({
  site: SITE,
  trailingSlash: "never",
  compressHTML: true,
  vite: {
    plugins: [tailwindcss()]
  },
  markdown: {
    remarkPlugins: [remarkGithubAlerts, [remarkRepoLinks, { tag: versions.core.tag }]]
  },
  integrations: [
    lastmod.integration,
    // Added explicitly so Starlight skips its own copy (it checks for an integration named
    // "@astrojs/sitemap"). sitemap-index.xml points to sitemap-website-0.xml (landing and legal
    // pages), sitemap-docs-0.xml (the nine docs destinations) and sitemap-api-0.xml (the generated
    // API reference). No other page is listed. Each <lastmod> moves only when the page's content
    // does (plugins/sitemap-lastmod.mjs, whose integration has to run first).
    sitemap({
      filter: (page) => sitemapUrls.has(stripSlash(page)) || isApiReferenceUrl(page),
      serialize: lastmod.serialize,
      chunks: {
        website: (item) => (isDocsUrl(item.url) ? undefined : item),
        docs: (item) => (isDocsUrl(item.url) && !isApiReferenceUrl(item.url) ? item : undefined),
        api: (item) => (isApiReferenceUrl(item.url) ? item : undefined)
      }
    }),
    starlight({
      title: "IndeRun",
      description:
        "On-device AI for the devices your users actually have: one API for Capacitor, web, iOS and Android.",
      favicon: "/favicon.svg",
      social: [{ icon: "github", label: "GitHub", href: REPOSITORY }],
      editLink: {
        // Docs live in ../docs; Starlight resolves the entry path against this base.
        baseUrl: `${REPOSITORY}/edit/dev/website/`
      },
      lastUpdated: false,
      customCss: ["./src/styles/docs.css"],
      components: {
        SkipLink: "./src/components/starlight/SkipLink.astro",
        SiteTitle: "./src/components/starlight/SiteTitle.astro",
        SocialIcons: "./src/components/starlight/SocialIcons.astro",
        Footer: "./src/components/starlight/Footer.astro"
      },
      /*
       * Code blocks are the enamel code plate in both themes (src/styles/code-theme.mjs). The frame
       * colours are CSS variables from docs.css so the plate edge and shadow follow the theme;
       * no window-dot title bar on shell blocks.
       */
      expressiveCode: {
        themes: [enamelCodeTheme],
        useStarlightUiThemeColors: false,
        useStarlightDarkModeSwitch: false,
        minSyntaxHighlightingColorContrast: 7,
        // Long lines wrap instead of scrolling; wrapped lines keep their indentation.
        defaultProps: { frame: "code", wrap: true },
        styleOverrides: {
          borderRadius: "6px",
          borderWidth: "1px",
          borderColor: "var(--ir-code-plate-edge)",
          codeBackground: "var(--ir-code-plate)",
          codeFontSize: "0.875rem",
          codeLineHeight: "1.7",
          codePaddingBlock: "1rem",
          codePaddingInline: "1.25rem",
          scrollbarThumbColor: "#77736d",
          scrollbarThumbHoverColor: "#969390",
          focusBorder: "#a0b3ff",
          frames: {
            frameBoxShadowCssValue: "var(--ir-code-plate-shadow)",
            editorBackground: "var(--ir-code-plate)",
            terminalBackground: "var(--ir-code-plate)",
            editorTabBarBackground: "var(--ir-code-plate)",
            editorActiveTabBackground: "var(--ir-code-plate)",
            editorActiveTabForeground: "#bdb7af",
            editorActiveTabIndicatorTopColor: "#a0b3ff",
            editorActiveTabIndicatorBottomColor: "transparent",
            editorTabBarBorderBottomColor: "var(--ir-code-plate-edge)",
            editorTabBorderRadius: "0",
            terminalTitlebarBackground: "var(--ir-code-plate)",
            terminalTitlebarForeground: "#bdb7af",
            terminalTitlebarBorderBottomColor: "var(--ir-code-plate-edge)",
            terminalTitlebarDotsOpacity: "0",
            inlineButtonForeground: "#e2dbd2",
            inlineButtonBackground: "#121212",
            inlineButtonBorder: "#969390",
            inlineButtonBackgroundIdleOpacity: "1",
            inlineButtonBackgroundHoverOrFocusOpacity: "1",
            tooltipSuccessBackground: "#a0b3ff",
            tooltipSuccessForeground: "#000000"
          },
          textMarkers: {
            markBackground: "#a0b3ff24",
            markBorderColor: "#a0b3ff"
          }
        }
      },
      routeMiddleware: "./src/routeData.ts",
      head: [
        // favicon.svg comes from `favicon` above; the .ico and the touch icon from the logo package.
        { tag: "link", attrs: { rel: "icon", href: "/favicon.ico", sizes: "32x32" } },
        { tag: "link", attrs: { rel: "apple-touch-icon", href: "/apple-touch-icon.png" } },
        { tag: "meta", attrs: { property: "og:image", content: `${SITE}/og/default.jpg` } },
        { tag: "meta", attrs: { property: "og:image:type", content: "image/jpeg" } },
        { tag: "meta", attrs: { property: "og:image:width", content: "1200" } },
        { tag: "meta", attrs: { property: "og:image:height", content: "630" } },
        {
          tag: "meta",
          attrs: {
            property: "og:image:alt",
            content:
              "IndeRun logo. On-device AI for the devices your users actually have. On-device when available, cloud only when you allow it. Runs on Apple Foundation Models, Gemini Nano, Chrome built-in AI and ONNX Runtime."
          }
        },
        { tag: "meta", attrs: { name: "twitter:image", content: `${SITE}/og/default.jpg` } },
        {
          tag: "meta",
          attrs: {
            name: "theme-color",
            content: THEME_COLORS.light,
            media: "(prefers-color-scheme: light)"
          }
        },
        {
          tag: "meta",
          attrs: {
            name: "theme-color",
            content: THEME_COLORS.dark,
            media: "(prefers-color-scheme: dark)"
          }
        },
        { tag: "script", content: themeColorScript }
      ],
      plugins: [
        capacitorTypeDoc({
          entryPoints: ["node_modules/@independo/capacitor-inderun/dist/index.d.ts"],
          tsconfig: "./tsconfig.typedoc.json",
          output: "docs/api/typescript/capacitor",
          typeDoc: typeDocOptions,
          sidebar: {
            label: `Capacitor plugin ${versions.capacitorPlugin.version}`,
            collapsed: true
          },
          pagination: true
        }),
        webTypeDoc({
          entryPoints: ["node_modules/@independo/inderun-web/dist/index.d.ts"],
          tsconfig: "./tsconfig.typedoc.json",
          output: "docs/api/typescript/web",
          typeDoc: typeDocOptions,
          sidebar: { label: `Web SDK ${versions.core.version}`, collapsed: true },
          pagination: true
        }),
        // "/" is the hand-built landing page (src/pages/index.astro), which the validator cannot
        // see; the 404 page links to it.
        starlightLinksValidator({ errorOnLocalLinks: true, exclude: ["/"] })
      ],
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Introduction", slug: "docs" },
            { label: "Capacitor quickstart", slug: "docs/getting-started/capacitor" },
            { label: "Local-first starter app", slug: "docs/getting-started/example" }
          ]
        },
        {
          label: "Core Concepts",
          collapsed: true,
          items: [
            { label: "Routing & privacy", slug: "docs/concepts/routing-and-privacy" },
            { label: "Architecture overview", slug: "docs/concepts/architecture" }
          ]
        },
        {
          label: "Guides",
          collapsed: true,
          items: [
            { label: "Read text aloud", slug: "docs/guides/speech" },
            { label: "Troubleshooting", slug: "docs/guides/troubleshooting" }
          ]
        },
        {
          label: "Platforms & Integrations",
          collapsed: true,
          items: [{ label: "Compatibility", slug: "docs/platforms/compatibility" }]
        },
        {
          label: "API Reference",
          collapsed: true,
          items: [
            { label: "TypeScript reference", slug: "docs/api/typescript" },
            capacitorTypeDocSidebar,
            webTypeDocSidebar
          ]
        },
        {
          label: "Project",
          collapsed: true,
          items: [
            external("Releases", `${REPOSITORY}/releases`),
            external("Migration guide", pinnedRepoUrl("docs/migration.md")),
            external("Contributing", pinnedRepoUrl("CONTRIBUTING.md")),
            external("License (MIT)", pinnedRepoUrl("LICENSE")),
            external(
              "Docs licence (CC BY-SA 4.0)",
              "https://creativecommons.org/licenses/by-sa/4.0/"
            ),
            external("Source", REPOSITORY)
          ]
        }
      ]
    })
  ]
});
