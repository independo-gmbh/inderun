import { describe, expect, it, vi } from "vitest";
import { handleProxyRequest } from "./handler.js";

describe("handleProxyRequest", () => {
  it("returns a config error when the default OpenAI endpoint is used without OPENAI_API_KEY", async () => {
    const response = await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ model: "ignored", input: "Hello" })
      }),
      {}
    );

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        message:
          "OPENAI_API_KEY is required when the IndeRun demo proxy targets the default OpenAI Responses endpoint."
      }
    });
  });

  it("relays an event stream as it arrives instead of buffering it", async () => {
    let closed = false;
    const upstream = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('data: {"type":"a"}\n\n'));
        },
        pull(controller) {
          // Withheld until the caller has already read the first chunk, so a
          // buffering proxy would deadlock rather than pass this.
          if (!firstChunkRead) return new Promise(() => undefined);
          controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
          controller.close();
          closed = true;
        }
      }),
      { status: 200, headers: { "Content-Type": "text/event-stream" } }
    );
    let firstChunkRead = false;
    const fetchImpl = vi.fn().mockResolvedValue(upstream);

    const response = await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input: "Hello", stream: true })
      }),
      { apiKey: "sk-test", fetchImpl }
    );

    expect(response.headers.get("Content-Type")).toBe("text/event-stream");
    expect(response.headers.get("Cache-Control")).toBe("no-cache");
    expect(JSON.parse(String(fetchImpl.mock.calls[0]![1].body))).toMatchObject({ stream: true });

    const decoder = new TextDecoder();
    const reader = response.body!.getReader();
    const first = await reader.read();
    firstChunkRead = true;
    expect(decoder.decode(first.value)).toBe('data: {"type":"a"}\n\n');
    expect(closed).toBe(false);
    await reader.cancel();
  });

  it("forwards the caller's abort signal upstream", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response("data: [DONE]\n\n", {
        status: 200,
        headers: { "Content-Type": "text/event-stream" }
      })
    );
    const controller = new AbortController();

    await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input: "Hello", stream: true }),
        signal: controller.signal
      }),
      { apiKey: "sk-test", fetchImpl }
    );

    // Without this, cancelling a stream leaves the upstream generation running
    // and billable until it finishes on its own.
    const forwarded = fetchImpl.mock.calls[0]![1].signal as AbortSignal;
    expect(forwarded).toBeInstanceOf(AbortSignal);
    expect(forwarded.aborted).toBe(false);
    controller.abort();
    expect(forwarded.aborted).toBe(true);
  });

  it("passes through upstream failures while forcing the configured model for the default OpenAI endpoint", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "Rate limited." } }), {
        status: 429,
        headers: {
          "Content-Type": "application/json"
        }
      })
    );

    const response = await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: "client-model",
          input: "Hello"
        })
      }),
      {
        apiKey: "sk-demo",
        model: "server-model",
        fetchImpl
      }
    );

    expect(fetchImpl).toHaveBeenCalledOnce();
    expect(fetchImpl.mock.calls[0]?.[0]).toBe("https://api.openai.com/v1/responses");
    expect(fetchImpl.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      headers: {
        Authorization: "Bearer sk-demo",
        "Content-Type": "application/json"
      }
    });

    const body = JSON.parse(String(fetchImpl.mock.calls[0]?.[1]?.body)) as Record<string, unknown>;
    expect(body.model).toBe("server-model");
    expect(body.input).toBe("Hello");

    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        message: "Rate limited."
      }
    });
  });

  it("forwards to a custom OpenAI-compatible endpoint without an auth header when no key is configured", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ output_text: "Local response." }), {
        status: 200,
        headers: {
          "Content-Type": "application/json"
        }
      })
    );

    const response = await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: "client-model",
          input: "Hello"
        })
      }),
      {
        endpointUrl: "http://localhost:11434/v1/responses",
        model: "ollama-model",
        fetchImpl
      }
    );

    expect(fetchImpl).toHaveBeenCalledOnce();
    expect(fetchImpl.mock.calls[0]?.[0]).toBe("http://localhost:11434/v1/responses");
    expect(fetchImpl.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      }
    });
    expect(
      (fetchImpl.mock.calls[0]?.[1]?.headers as Record<string, string>).Authorization
    ).toBeUndefined();

    const body = JSON.parse(String(fetchImpl.mock.calls[0]?.[1]?.body)) as Record<string, unknown>;
    expect(body.model).toBe("ollama-model");
    expect(response.status).toBe(200);
  });

  it("forwards to a custom OpenAI-compatible endpoint with an auth header when a key is configured", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ output_text: "Gateway response." }), {
        status: 200,
        headers: {
          "Content-Type": "application/json"
        }
      })
    );

    await handleProxyRequest(
      new Request("http://localhost/api/inderun/openai-responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: "client-model",
          input: "Hello"
        })
      }),
      {
        apiKey: "gateway-key",
        endpointUrl: "https://gateway.example/v1/responses",
        fetchImpl
      }
    );

    expect(fetchImpl.mock.calls[0]?.[0]).toBe("https://gateway.example/v1/responses");
    expect(fetchImpl.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      headers: {
        Authorization: "Bearer gateway-key",
        "Content-Type": "application/json"
      }
    });
  });
});
