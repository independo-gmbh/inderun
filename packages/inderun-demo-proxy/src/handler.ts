import { DEFAULT_OPENAI_MODEL, DEFAULT_OPENAI_RESPONSES_URL } from "./shared.js";

export interface DemoProxyRequestOptions {
  apiKey?: string;
  model?: string;
  endpointUrl?: string;
  fetchImpl?: typeof fetch;
}

export async function handleProxyRequest(
  request: Request,
  options: DemoProxyRequestOptions
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonResponse(
      405,
      {
        error: {
          message: "Only POST is supported for the IndeRun demo proxy."
        }
      },
      { Allow: "POST" }
    );
  }

  const endpointUrl = options.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_URL;
  const isDefaultOpenAIEndpoint = endpointUrl === DEFAULT_OPENAI_RESPONSES_URL;

  if (isDefaultOpenAIEndpoint && !options.apiKey) {
    return jsonResponse(500, {
      error: {
        message:
          "OPENAI_API_KEY is required when the IndeRun demo proxy targets the default OpenAI Responses endpoint."
      }
    });
  }

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse(400, {
      error: {
        message: "Request body must be valid JSON."
      }
    });
  }

  if (!isRecord(payload)) {
    return jsonResponse(400, {
      error: {
        message: "Request body must be a JSON object."
      }
    });
  }

  const upstreamBody = {
    ...payload,
    model: options.model ?? getString(payload.model) ?? DEFAULT_OPENAI_MODEL
  };

  const headers: Record<string, string> = {
    "Content-Type": "application/json"
  };

  if (options.apiKey) {
    headers.Authorization = `Bearer ${options.apiKey}`;
  }

  const fetchImpl = options.fetchImpl ?? fetch;
  const upstream = await fetchImpl(endpointUrl, {
    method: "POST",
    headers,
    body: JSON.stringify(upstreamBody)
  });

  return new Response(await upstream.text(), {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: {
      "Content-Type": upstream.headers.get("Content-Type") ?? "application/json"
    }
  });
}

export function jsonResponse(
  status: number,
  body: Record<string, unknown>,
  headers: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers
    }
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function getString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
