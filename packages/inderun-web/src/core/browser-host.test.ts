import { afterEach, describe, expect, it } from "vitest";
import { FetchHttpClient } from "./browser-host.js";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("FetchHttpClient", () => {
  it("binds the default global fetch so browser Window.fetch does not fail as an illegal invocation", async () => {
    globalThis.fetch = function fetchWithRequiredThis(this: typeof globalThis) {
      if (this !== globalThis) {
        throw new TypeError("Illegal invocation");
      }

      return Promise.resolve(
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          statusText: "OK",
          headers: {
            "Content-Type": "application/json"
          }
        })
      );
    } as typeof fetch;

    const client = new FetchHttpClient();
    const response = await client.send({
      method: "POST",
      url: "/api/inderun/openai-responses",
      body: JSON.stringify({ input: "hello" })
    });

    expect(response).toMatchObject({
      status: 200,
      statusText: "OK",
      body: JSON.stringify({ ok: true })
    });
    expect(response.headers["content-type"]).toBe("application/json");
  });
});
