/**
 * The browser UI colour (`<meta name="theme-color">`) follows the theme the visitor picked, not
 * only the OS setting. The two `media` variants in the head cover the no-JavaScript case; this
 * script then pins every `theme-color` meta to the active `<html data-theme>` and follows later
 * changes from either theme picker (the landing header's or Starlight's). Shared by
 * src/layouts/Site.astro and the Starlight head in astro.config.mjs.
 */
export const THEME_COLORS = { light: "#FAF5EF", dark: "#000000" };

export const themeColorScript = `(() => {
  const root = document.documentElement;
  const colors = ${JSON.stringify(THEME_COLORS)};
  const sync = () => {
    const theme = root.dataset.theme;
    if (theme !== "light" && theme !== "dark") return;
    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
      meta.removeAttribute("media");
      meta.content = colors[theme];
    }
  };
  new MutationObserver(sync).observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  document.addEventListener("DOMContentLoaded", sync);
})();`;
