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
    expect((fetchImpl.mock.calls[0]?.[1]?.headers as Record<string, string>).Authorization).toBeUndefined();

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
