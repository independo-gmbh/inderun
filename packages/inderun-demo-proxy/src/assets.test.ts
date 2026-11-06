import {
  createServer,
  request as httpRequest,
  type IncomingHttpHeaders,
  type Server
} from "node:http";
import { AddressInfo } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import { loadAssetAllowlist } from "./assets.js";
import { createDemoProxyServer } from "./server.js";

const LISTED = "https://example.test/releases/download/v1/model.onnx";
const PREFIX_ONLY = "https://example.test/releases/download/v1/model.onnx.evil";

describe("GET /assets", () => {
  const servers: Server[] = [];
  const received: Array<{ url?: string; headers: IncomingHttpHeaders }> = [];

  afterEach(async () => {
    received.length = 0;
    await Promise.all(
      servers.splice(0).map(
        (server) =>
          new Promise<void>((resolve) => {
            server.closeAllConnections?.();
            server.close(() => resolve());
          })
      )
    );
  });

  async function listen(server: Server): Promise<string> {
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  }

  let redirectTo = "/final";
  let hold = false;
  let upstreamClosed = false;

  async function setup(status = 200) {
    redirectTo = "/final";
    upstreamClosed = false;
    const upstream = await listen(
      createServer((req, res) => {
        received.push({ url: req.url, headers: req.headers });
        if (req.url === "/redirect") {
          res.writeHead(302, { Location: redirectTo });
          res.end();
          return;
        }
        if (status !== 200) {
          res.writeHead(status);
          res.end();
          return;
        }
        if (hold) {
          res.writeHead(200, { "Content-Type": "application/octet-stream" });
          res.write("partial");
          res.on("close", () => (upstreamClosed = true));
          return;
        }
        res.writeHead(200, { "Content-Type": "application/octet-stream", "Content-Length": "7" });
        res.end("weights");
      })
    );
    // The catalog's real URLs point at the internet; route example.test to the fake instead.
    const assetFetch: typeof fetch = (input, init) => {
      const url = new URL(String(input));
      if (url.hostname !== "example.test") return fetch(input, init);
      const path = url.pathname === "/redirect" || url.pathname === "/final" ? url.pathname : null;
      return fetch(`${upstream}${path ?? (input === LISTED ? "/redirect" : "/x")}`, init);
    };
    const proxy = await listen(
      createDemoProxyServer({
        endpointUrl: "http://unused.invalid",
        model: "m",
        host: "127.0.0.1",
        port: 0,
        corsOrigin: "https://demo.test",
        assetAllowlist: new Set([LISTED]),
        assetFetch
      })
    );
    return proxy;
  }

  const asset = (proxy: string, url: string, init?: RequestInit) =>
    fetch(`${proxy}/assets?url=${encodeURIComponent(url)}`, init);

  it("streams a listed asset after following the redirect, with CORS and length", async () => {
    const proxy = await setup();
    const response = await asset(proxy, LISTED);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("weights");
    expect(response.headers.get("access-control-allow-origin")).toBe("https://demo.test");
    expect(response.headers.get("content-length")).toBe("7");
    expect(response.headers.get("content-type")).toBe("application/octet-stream");
    expect(received.map((r) => r.url)).toEqual(["/redirect", "/final"]);
  });

  it("refuses unlisted and prefix-only URLs without calling upstream", async () => {
    const proxy = await setup();
    for (const url of ["https://other.test/x", PREFIX_ONLY, "not a url"]) {
      expect((await asset(proxy, url)).status).toBe(403);
    }
    expect((await fetch(`${proxy}/assets`)).status).toBe(403);
    expect(received).toHaveLength(0);
  });

  it("does not forward client headers upstream", async () => {
    const proxy = await setup();
    await (
      await asset(proxy, LISTED, {
        headers: { cookie: "session=1", authorization: "Bearer secret", "x-custom": "1" }
      })
    ).arrayBuffer();
    expect(received.length).toBeGreaterThan(0);
    for (const { headers } of received) {
      expect(headers.cookie).toBeUndefined();
      expect(headers.authorization).toBeUndefined();
      expect(headers["x-custom"]).toBeUndefined();
    }
  });

  it("maps upstream 404 to 404 and other failures to 502", async () => {
    const missing = await asset(await setup(404), LISTED);
    expect(missing.status).toBe(404);
    expect(await missing.text()).toContain("asset not published yet (HTTP 404)");
    expect(received.length).toBeGreaterThan(0);
  });

  it("maps upstream 500 to 502", async () => {
    expect((await asset(await setup(500), LISTED)).status).toBe(502);
  });

  it("rejects non-GET methods", async () => {
    const proxy = await setup();
    const response = await fetch(`${proxy}/assets?url=${encodeURIComponent(LISTED)}`, {
      method: "POST"
    });
    expect(response.status).toBe(405);
  });

  it("derives the allowlist from the committed catalog", () => {
    const list = loadAssetAllowlist();
    expect(list.size).toBeGreaterThan(0);
    for (const url of list) expect(url).toMatch(/^https:\/\//);
  });

  it("refuses an http redirect target without contacting it", async () => {
    const proxy = await setup();
    const contacted: string[] = [];
    const target = await listen(createServer((req) => contacted.push(req.url ?? "")));
    redirectTo = `${target}/never`;
    expect((await asset(proxy, LISTED)).status).toBe(502);
    expect(contacted).toEqual([]);
  });

  it("gives up after too many redirects", async () => {
    const proxy = await setup();
    redirectTo = "/redirect";
    expect((await asset(proxy, LISTED)).status).toBe(502);
  });

  it("cancels the upstream when the client aborts mid-body", async () => {
    hold = true;
    try {
      const proxy = await setup();
      redirectTo = "/hold";
      const controller = new AbortController();
      const response = await asset(proxy, LISTED, { signal: controller.signal });
      await response.body!.getReader().read();
      controller.abort();
      await vi.waitFor(() => expect(upstreamClosed).toBe(true));
    } finally {
      hold = false;
    }
  });

  it("refuses double-encoded and duplicated url parameters", async () => {
    const proxy = await setup();
    const once = encodeURIComponent(LISTED);
    expect((await fetch(`${proxy}/assets?url=${encodeURIComponent(once)}`)).status).toBe(403);
    expect(
      (await fetch(`${proxy}/assets?url=https%3A%2F%2Fother.test%2Fx&url=${once}`)).status
    ).toBe(403);
    expect(received).toHaveLength(0);
  });

  it("answers TRACE with 405 and keeps serving", async () => {
    const proxy = await setup();
    const { port } = new URL(proxy);
    const status = await new Promise<number>((resolve, reject) => {
      const req = httpRequest(
        { host: "127.0.0.1", port, method: "TRACE", path: "/assets?url=x" },
        (res) => {
          res.resume();
          resolve(res.statusCode ?? 0);
        }
      );
      req.on("error", reject);
      req.end();
    });
    expect(status).toBe(405);
    expect((await asset(proxy, LISTED)).status).toBe(200);
  });
});
