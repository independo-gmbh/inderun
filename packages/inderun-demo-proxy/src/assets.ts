import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { jsonResponse } from "./handler.js";

export interface AssetRequestOptions {
  /** Exact URLs that may be fetched. Anything else is refused. */
  allowlist: ReadonlySet<string>;
  /** Injected in tests; defaults to the global `fetch`. */
  fetchImpl?: typeof fetch;
}

/** Where the catalog lives in the workspace, relative to `src/` and `dist/` alike. */
export const DEFAULT_ASSET_CATALOG_PATH = fileURLToPath(
  new URL("../../../contracts/fixtures/speech/neural-model-catalog.json", import.meta.url)
);

interface CatalogShape {
  entries?: Array<{
    files?: Array<{ url?: unknown }>;
    voices?: Array<{ file?: { url?: unknown } }>;
  }>;
}

/** Every `files[].url` and `voices[].file.url` of the neural model catalog. */
export function loadAssetAllowlist(catalogPath: string = DEFAULT_ASSET_CATALOG_PATH): Set<string> {
  const catalog = JSON.parse(readFileSync(catalogPath, "utf8")) as CatalogShape;
  const urls = new Set<string>();
  for (const entry of catalog.entries ?? []) {
    for (const file of entry.files ?? []) {
      if (typeof file.url === "string") urls.add(file.url);
    }
    for (const voice of entry.voices ?? []) {
      if (typeof voice.file?.url === "string") urls.add(voice.file.url);
    }
  }
  return urls;
}

/**
 * `GET /assets?url=<encoded catalog url>`: relays a catalog asset. GitHub's release
 * download answers 302 without CORS headers, so the browser cannot fetch it itself.
 * Only exact catalog URLs are served, and no client header ever goes upstream.
 */
export async function handleAssetRequest(
  request: Request,
  options: AssetRequestOptions
): Promise<Response> {
  if (request.method !== "GET") {
    return jsonResponse(405, { error: { message: "Only GET is supported." } }, { Allow: "GET" });
  }

  const target = new URL(request.url).searchParams.get("url");
  if (target === null || !options.allowlist.has(target)) {
    return jsonResponse(403, { error: { message: "URL is not a catalog asset." } });
  }

  let upstream: Response;
  try {
    upstream = await fetchFollowingHttps(target, options.fetchImpl ?? fetch, request.signal);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return jsonResponse(502, { error: { message: `Asset fetch failed: ${message}` } });
  }

  if (upstream.status === 404) {
    await upstream.body?.cancel().catch(() => undefined);
    return jsonResponse(404, { error: { message: "asset not published yet (HTTP 404)" } });
  }
  if (!upstream.ok) {
    await upstream.body?.cancel().catch(() => undefined);
    return jsonResponse(502, {
      error: { message: `Asset upstream answered HTTP ${upstream.status}.` }
    });
  }

  const headers = new Headers();
  headers.set("Content-Type", upstream.headers.get("Content-Type") ?? "application/octet-stream");
  const length = upstream.headers.get("Content-Length");
  if (length !== null && !upstream.headers.has("Content-Encoding")) {
    headers.set("Content-Length", length);
  }
  return new Response(upstream.body, { status: 200, headers });
}

const MAX_REDIRECT_HOPS = 5;

/** Follows redirects by hand so that every hop can be held to https and a hop cap. */
async function fetchFollowingHttps(
  start: string,
  fetchImpl: typeof fetch,
  signal: AbortSignal
): Promise<Response> {
  let current = start;
  for (let hop = 0; hop <= MAX_REDIRECT_HOPS; hop++) {
    const response = await fetchImpl(current, {
      method: "GET",
      redirect: "manual",
      // Deliberately not the client's headers: cookies and credentials stay here.
      headers: { "Accept-Encoding": "identity" },
      signal
    });
    const location = response.headers.get("Location");
    if (response.status < 300 || response.status >= 400 || location === null) return response;
    await response.body?.cancel().catch(() => undefined);
    const next = new URL(location, current);
    if (next.protocol !== "https:") throw new Error("redirect to a non-https location refused");
    current = next.href;
  }
  throw new Error("too many redirects");
}
