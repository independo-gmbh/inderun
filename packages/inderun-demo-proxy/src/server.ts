import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveDemoProxyConfig, type DemoProxyConfig } from "./config.js";
import { handleProxyRequest, jsonResponse } from "./handler.js";
import { DEMO_PROXY_PATH } from "./shared.js";

export function createDemoProxyServer(config: DemoProxyConfig = resolveDemoProxyConfig()): Server {
  return createServer(async (req, res) => {
    const pathname = (req.url ?? "").split("?")[0];

    if (req.method === "OPTIONS") {
      logRequest(req, pathname);
      writeCorsHeaders(res, config);
      res.statusCode = 204;
      res.end();
      return;
    }

    if (pathname === "/health") {
      logRequest(req, pathname);
      await writeNodeResponse(
        res,
        jsonResponse(200, {
          status: "ok",
          endpointUrl: config.endpointUrl,
          model: config.model,
          authConfigured: Boolean(config.apiKey)
        }),
        config
      );
      return;
    }

    if (pathname !== DEMO_PROXY_PATH) {
      logRequest(req, pathname);
      await writeNodeResponse(
        res,
        jsonResponse(404, {
          error: {
            message: "Route not found."
          }
        }),
        config
      );
      return;
    }

    try {
      logRequest(req, pathname);
      const request = await toWebRequest(req);
      const response = await handleProxyRequest(request, {
        apiKey: config.apiKey,
        model: config.model,
        endpointUrl: config.endpointUrl
      });
      await writeNodeResponse(res, response, config);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await writeNodeResponse(
        res,
        jsonResponse(502, {
          error: {
            message: `The IndeRun demo proxy failed before receiving an upstream response: ${message}`
          }
        }),
        config
      );
    }
  });
}

function logRequest(req: IncomingMessage, pathname: string): void {
  console.log(`[IndeRun demo proxy] ${req.method ?? "UNKNOWN"} ${pathname}`);
}

async function toWebRequest(req: IncomingMessage): Promise<Request> {
  const origin = `http://${req.headers.host ?? "localhost"}`;
  const url = new URL(req.url ?? DEMO_PROXY_PATH, origin);
  const body =
    req.method === "GET" || req.method === "HEAD" ? undefined : await readNodeBody(req);

  return new Request(url, {
    method: req.method,
    headers: normalizeHeaders(req.headers),
    body: body ? new Uint8Array(body) : undefined
  });
}

async function writeNodeResponse(
  res: ServerResponse,
  response: Response,
  config: DemoProxyConfig
): Promise<void> {
  res.statusCode = response.status;
  res.statusMessage = response.statusText;

  response.headers.forEach((value, key) => {
    res.setHeader(key, value);
  });

  writeCorsHeaders(res, config);

  const buffer = Buffer.from(await response.arrayBuffer());
  res.end(buffer);
}

function writeCorsHeaders(res: ServerResponse, config: DemoProxyConfig): void {
  res.setHeader("Access-Control-Allow-Origin", config.corsOrigin);
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

function readNodeBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolveBody, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    req.on("end", () => resolveBody(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function normalizeHeaders(headers: IncomingMessage["headers"]): HeadersInit {
  const normalized = new Headers();

  for (const [key, value] of Object.entries(headers)) {
    if (value === undefined) {
      continue;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        normalized.append(key, item);
      }
      continue;
    }

    normalized.set(key, value);
  }

  return normalized;
}

function isDirectRun(): boolean {
  return process.argv[1] !== undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
}

if (isDirectRun()) {
  const config = resolveDemoProxyConfig();
  const server = createDemoProxyServer(config);

  server.listen(config.port, config.host, () => {
    console.log(
      `IndeRun demo proxy listening on http://${config.host}:${config.port}${DEMO_PROXY_PATH}`
    );
  });
}
