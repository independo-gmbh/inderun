import { afterEach, describe, expect, it } from "vitest";
import { SystemModelRuntimeError } from "./system-model-runtime.js";
import { createChromePromptApiRuntime } from "./system-model-chrome-runtime.js";

interface FakeSession {
  prompt: (input: string, options?: { signal?: AbortSignal }) => Promise<string>;
  destroy: () => void;
}

interface FakeLanguageModel {
  availability: (options?: Record<string, unknown>) => Promise<string>;
  create: (options?: Record<string, unknown>) => Promise<FakeSession>;
}

const originalLanguageModel = Object.getOwnPropertyDescriptor(globalThis, "LanguageModel");

function setLanguageModel(value: unknown): void {
  Object.defineProperty(globalThis, "LanguageModel", {
    value,
    configurable: true,
    writable: true
  });
}

afterEach(() => {
  if (originalLanguageModel) {
    Object.defineProperty(globalThis, "LanguageModel", originalLanguageModel);
  } else {
    Reflect.deleteProperty(globalThis, "LanguageModel");
  }
});

function createFakeLanguageModel(overrides: Partial<FakeLanguageModel> = {}): {
  languageModel: FakeLanguageModel;
  destroyCalls: number;
} {
  let destroyCalls = 0;

  const languageModel: FakeLanguageModel = {
    availability: async () => "available",
    create: async () => ({
      prompt: async () => "hello from prompt api",
      destroy: () => {
        destroyCalls += 1;
      }
    }),
    ...overrides
  };

  return { languageModel, destroyCalls };
}

describe("createChromePromptApiRuntime availability", () => {
  it("reports api_missing when LanguageModel is not defined", async () => {
    Reflect.deleteProperty(globalThis, "LanguageModel");
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("api_missing");
    expect(availability.reason).toContain("system model API missing");
  });

  it("maps the 'available' result", async () => {
    setLanguageModel(createFakeLanguageModel().languageModel);
    const runtime = createChromePromptApiRuntime();

    await expect(runtime.availability()).resolves.toEqual({ kind: "available" });
  });

  it("maps the 'downloadable' result", async () => {
    setLanguageModel(
      createFakeLanguageModel({ availability: async () => "downloadable" }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("downloadable");
    expect(availability.reason).toContain("downloadable");
  });

  it("maps the 'downloading' result", async () => {
    setLanguageModel(
      createFakeLanguageModel({ availability: async () => "downloading" }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("downloading");
    expect(availability.reason).toContain("downloading");
  });

  it("maps the 'unavailable' result to model_unavailable", async () => {
    setLanguageModel(
      createFakeLanguageModel({ availability: async () => "unavailable" }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("model_unavailable");
    expect(availability.reason).toContain("model is unavailable");
  });

  it("maps a NotSupportedError thrown by availability() to browser_unsupported", async () => {
    setLanguageModel(
      createFakeLanguageModel({
        availability: async () => {
          throw new DOMException("nope", "NotSupportedError");
        }
      }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("browser_unsupported");
  });

  it("maps a NotAllowedError thrown by availability() to feature_disabled", async () => {
    setLanguageModel(
      createFakeLanguageModel({
        availability: async () => {
          throw new DOMException("nope", "NotAllowedError");
        }
      }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("feature_disabled");
  });

  it("maps an unexpected throw from availability() to unavailable", async () => {
    setLanguageModel(
      createFakeLanguageModel({
        availability: async () => {
          throw new Error("boom");
        }
      }).languageModel
    );
    const runtime = createChromePromptApiRuntime();

    const availability = await runtime.availability();

    expect(availability.kind).toBe("unavailable");
    expect(availability.reason).toContain("provider temporarily unavailable");
  });

  it("passes the same options to availability() that generate() will use to create a session", async () => {
    const seen: Array<Record<string, unknown> | undefined> = [];
    setLanguageModel(
      createFakeLanguageModel({
        availability: async (options) => {
          seen.push(options);
          return "available";
        }
      }).languageModel
    );
    const runtime = createChromePromptApiRuntime({ generation: { temperature: 0.3 } });

    await runtime.availability();
    await runtime.generate({ messages: [{ role: "user", content: "Hi." }] });

    expect(seen[0]).toMatchObject({ temperature: 0.3 });
  });
});

describe("createChromePromptApiRuntime generate", () => {
  it("creates a session, prompts it, and destroys it", async () => {
    const { languageModel } = createFakeLanguageModel();
    let destroyCalls = 0;
    languageModel.create = async () => ({
      prompt: async (input) => `echo:${input}`,
      destroy: () => {
        destroyCalls += 1;
      }
    });
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const output = await runtime.generate({ messages: [{ role: "user", content: "Hi." }] });

    expect(output.text).toBe("echo:user: Hi.");
    expect(destroyCalls).toBe(1);
  });

  it("destroys the session even when prompt() throws", async () => {
    const { languageModel } = createFakeLanguageModel();
    let destroyCalls = 0;
    languageModel.create = async () => ({
      prompt: async () => {
        throw new Error("prompt failed");
      },
      destroy: () => {
        destroyCalls += 1;
      }
    });
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect(destroyCalls).toBe(1);
  });

  it("maps a NotSupportedError from create() to a capability error", async () => {
    const { languageModel } = createFakeLanguageModel();
    languageModel.create = async () => {
      throw new DOMException("no hardware", "NotSupportedError");
    };
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const error = await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect(error).toBeInstanceOf(SystemModelRuntimeError);
    expect((error as SystemModelRuntimeError).kind).toBe("capability");
    expect((error as SystemModelRuntimeError).message).toContain("hardware unsupported");
  });

  it("maps a NotAllowedError from create() to a capability error", async () => {
    const { languageModel } = createFakeLanguageModel();
    languageModel.create = async () => {
      throw new DOMException("disabled", "NotAllowedError");
    };
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const error = await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as SystemModelRuntimeError).kind).toBe("capability");
    expect((error as SystemModelRuntimeError).message).toContain("feature disabled");
  });

  it("maps a QuotaExceededError from create() to an unavailable error", async () => {
    const { languageModel } = createFakeLanguageModel();
    languageModel.create = async () => {
      throw new DOMException("no room", "QuotaExceededError");
    };
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const error = await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as SystemModelRuntimeError).kind).toBe("unavailable");
    expect((error as SystemModelRuntimeError).message).toContain("storage or network");
  });

  it("maps an AbortError from create() to a timeout error", async () => {
    const { languageModel } = createFakeLanguageModel();
    languageModel.create = async () => {
      throw new DOMException("aborted", "AbortError");
    };
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const error = await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as SystemModelRuntimeError).kind).toBe("timeout");
  });

  it("maps an unexpected DOMException name from create() to an internal error", async () => {
    const { languageModel } = createFakeLanguageModel();
    languageModel.create = async () => {
      throw new DOMException("weird", "UnknownError");
    };
    setLanguageModel(languageModel);
    const runtime = createChromePromptApiRuntime();

    const error = await runtime
      .generate({ messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as SystemModelRuntimeError).kind).toBe("internal");
  });
});
