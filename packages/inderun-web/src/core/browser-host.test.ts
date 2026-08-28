import { afterEach, describe, expect, it } from "vitest";
import { FetchHttpClient, FetchStreamingHttpClient } from "./browser-host.js";

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

describe("FetchStreamingHttpClient", () => {
  function encoded(text: string): Uint8Array {
    return new TextEncoder().encode(text);
  }

  function streamOf(
    chunks: string[],
    options: { onCancel?: () => void; gate?: Promise<void> } = {}
  ): ReadableStream<Uint8Array> {
    let index = 0;
    return new ReadableStream<Uint8Array>({
      async pull(controller) {
        if (index === 1 && options.gate) await options.gate;
        if (index >= chunks.length) {
          controller.close();
          return;
        }
        controller.enqueue(encoded(chunks[index]!));
        index += 1;
      },
      cancel() {
        options.onCancel?.();
      }
    });
  }

  async function collect(body: AsyncIterable<Uint8Array>): Promise<string[]> {
    const decoder = new TextDecoder();
    const out: string[] = [];
    for await (const chunk of body) out.push(decoder.decode(chunk));
    return out;
  }

  it("resolves the response head with lower-cased headers", async () => {
    globalThis.fetch = (() =>
      Promise.resolve(
        new Response(streamOf(["data: a\n\n"]), {
          status: 200,
          statusText: "OK",
          headers: { "Content-Type": "text/event-stream" }
        })
      )) as typeof fetch;

    const client = new FetchStreamingHttpClient();
    const response = await client.stream({ method: "POST", url: "/stream" });

    expect(response.status).toBe(200);
    expect(response.statusText).toBe("OK");
    expect(response.headers["content-type"]).toBe("text/event-stream");
    expect(await collect(response.body)).toEqual(["data: a\n\n"]);
  });

  it("yields body chunks incrementally rather than buffering", async () => {
    globalThis.fetch = (() =>
      Promise.resolve(
        new Response(streamOf(["one", "two", "three"]), { status: 200, statusText: "OK" })
      )) as typeof fetch;

    const client = new FetchStreamingHttpClient();
    const response = await client.stream({ method: "GET", url: "/stream" });

    expect(await collect(response.body)).toEqual(["one", "two", "three"]);
  });

  it("exposes a non-2xx head so callers can classify it before reading the body", async () => {
    globalThis.fetch = (() =>
      Promise.resolve(
        new Response('{"error":{"message":"slow down"}}', {
          status: 429,
          statusText: "Too Many Requests",
          headers: { "Retry-After": "3" }
        })
      )) as typeof fetch;

    const client = new FetchStreamingHttpClient();
    const response = await client.stream({ method: "POST", url: "/stream" });

    expect(response.status).toBe(429);
    expect(response.headers["retry-after"]).toBe("3");
    expect((await collect(response.body)).join("")).toBe('{"error":{"message":"slow down"}}');
  });

  it("tears down the connection when the caller's signal aborts mid-body", async () => {
    let cancelled = false;
    let releaseSecondChunk: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      releaseSecondChunk = resolve;
    });
    globalThis.fetch = (() => {
      const stream = streamOf(["first", "second"], {
        gate,
        onCancel: () => {
          cancelled = true;
        }
      });
      return Promise.resolve(new Response(stream, { status: 200, statusText: "OK" }));
    }) as typeof fetch;

    const controller = new AbortController();
    const client = new FetchStreamingHttpClient();
    const response = await client.stream({ method: "GET", url: "/stream" }, controller.signal);

    const received: string[] = [];
    const decoder = new TextDecoder();
    await expect(
      (async () => {
        for await (const chunk of response.body) {
          received.push(decoder.decode(chunk));
          controller.abort();
          releaseSecondChunk?.();
        }
      })()
    ).rejects.toThrow();

    expect(received).toEqual(["first"]);
    expect(cancelled).toBe(true);
  });

  it("rejects before the head when the time-to-first-byte budget expires", async () => {
    globalThis.fetch = ((_url: string, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(Object.assign(new Error("aborted"), { name: "AbortError" }));
        });
      })) as typeof fetch;

    const client = new FetchStreamingHttpClient();
    await expect(
      client.stream({ method: "GET", url: "/stream", timeoutMs: 5 })
    ).rejects.toMatchObject({ name: "AbortError" });
  });

  it("does not abort a long-lived body once the head has arrived", async () => {
    let aborted = false;
    globalThis.fetch = ((_url: string, init?: RequestInit) => {
      init?.signal?.addEventListener("abort", () => {
        aborted = true;
      });
      return Promise.resolve(new Response(streamOf(["chunk"]), { status: 200, statusText: "OK" }));
    }) as typeof fetch;

    const client = new FetchStreamingHttpClient();
    const response = await client.stream({ method: "GET", url: "/stream", timeoutMs: 5 });
    await new Promise((resolve) => setTimeout(resolve, 25));

    expect(aborted).toBe(false);
    expect(await collect(response.body)).toEqual(["chunk"]);
  });
});
