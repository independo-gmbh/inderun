import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseSseStream, type SseEvent } from "./sse.js";

interface FramingCase {
  name: string;
  description: string;
  chunksHex: string[];
  expected: SseEvent[];
}

const fixturePath = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../contracts/fixtures/streaming/sse-framing.json"
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { cases: FramingCase[] };

function toChunks(chunksHex: string[]): AsyncIterable<Uint8Array> {
  return (async function* () {
    for (const hex of chunksHex) {
      yield Uint8Array.from(hex.match(/../g) ?? [], (byte) => parseInt(byte, 16));
    }
  })();
}

async function collect(chunks: AsyncIterable<Uint8Array>): Promise<SseEvent[]> {
  const out: SseEvent[] = [];
  for await (const event of parseSseStream(chunks)) out.push(event);
  return out;
}

describe("parseSseStream", () => {
  it("covers every shared conformance case", () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const testCase of fixture.cases) {
    it(`${testCase.name}: ${testCase.description}`, async () => {
      expect(await collect(toChunks(testCase.chunksHex))).toEqual(testCase.expected);
    });
  }

  it("is unaffected by how the byte stream is chunked", async () => {
    const raw = new TextEncoder().encode("event: a\ndata: one\n\ndata: two\n\n");
    const perByte = (async function* () {
      for (const byte of raw) yield Uint8Array.of(byte);
    })();

    expect(await collect(perByte)).toEqual([{ event: "a", data: "one" }, { data: "two" }]);
  });
});
