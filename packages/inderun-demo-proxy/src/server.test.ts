import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { createDemoProxyServer } from "./server.js";
import { DEMO_PROXY_PATH } from "./shared.js";

/**
 * Exercises the relay against a real upstream rather than a mock: the behavior
 * under test is what happens to the upstream connection when the downstream
 * client disappears, which only a real socket can demonstrate.
 */
describe("createDemoProxyServer streaming relay", () => {
  const servers: Server[] = [];

  afterEach(async () => {
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
    const { port } = server.address() as AddressInfo;
    return `http://127.0.0.1:${port}`;
  }

  it("stops the upstream generation when the client disconnects", async () => {
    let upstreamClosed: () => void;
    const upstreamDisconnected = new Promise<void>((resolve) => {
      upstreamClosed = resolve;
    });

    let timer: ReturnType<typeof setInterval> | undefined;
    const upstreamUrl = await listen(
      createServer((_req, res) => {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.write('data: {"type":"response.output_text.delta","delta":"one"}\n\n');
        // Keeps generating until someone hangs up, like a long completion would.
        timer = setInterval(() => res.write("data: keep-alive\n\n"), 20);
        res.on("close", () => {
          if (timer) clearInterval(timer);
          upstreamClosed();
        });
      })
    );

    const proxyUrl = await listen(
      createDemoProxyServer({
        endpointUrl: `${upstreamUrl}/v1/responses`,
        model: "gpt-5.2",
        host: "127.0.0.1",
        port: 0,
        corsOrigin: "*"
      })
    );

    const controller = new AbortController();
    const response = await fetch(`${proxyUrl}${DEMO_PROXY_PATH}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input: "Hello", stream: true }),
      signal: controller.signal
    });

    expect(response.headers.get("content-type")).toBe("text/event-stream");

    const reader = response.body!.getReader();
    const first = await reader.read();
    expect(new TextDecoder().decode(first.value)).toContain("response.output_text.delta");

    controller.abort();

    // Without the disconnect being propagated, the model keeps generating — and
    // billing — until it finishes on its own.
    await expect(upstreamDisconnected).resolves.toBeUndefined();
  });
});
