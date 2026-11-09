import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { ValidateFunction } from "ajv";
import Ajv2020 from "ajv/dist/2020.js";
import { describe, expect, it } from "vitest";

// The report every speech benchmark harness writes (#276). Swift, Kotlin, web and the iPhone
// harness all produce documents that must validate against this schema, and every committed
// report must name only utterances the shared corpus has.
const fixturesDir = fileURLToPath(new URL("../../../contracts/fixtures/speech/", import.meta.url));
const reportsDir = fileURLToPath(new URL("../../../docs/verification/reports/", import.meta.url));
const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"));

const schema = readJson(`${fixturesDir}speech-benchmark-report.schema.json`) as object;
const Ajv2020Constructor = ((Ajv2020 as unknown as { default?: unknown }).default ??
  Ajv2020) as typeof Ajv2020;
const ajv = new Ajv2020Constructor({ allErrors: true, strict: true });
// Compiled lazily so a schema error fails the "compiles" test, not the whole file.
let compiled: ValidateFunction | undefined;
const compile = (): ValidateFunction => (compiled ??= ajv.compile(schema));
const validate = (data: unknown): boolean => compile()(data) as boolean;
const errorsOf = (): string => JSON.stringify(compile().errors);

const sample = {
  scenario: "render_speed",
  step: "warm",
  utteranceId: "de_de_short",
  requestedLocale: "de-DE",
  renderMs: 12.5
};
const stats = [
  {
    scenario: "render_speed",
    step: "warm",
    utteranceId: "de_de_short",
    metrics: { renderMs: 12.5 }
  }
];
type Report = Record<string, unknown> & { samples: Array<Record<string, unknown>> };
const minimalReport = (): Report => ({
  schema: "inderun-speech-benchmark/1",
  harness: "sdk_tests",
  createdAt: "2026-11-09T10:00:00Z",
  device: "test-device",
  os: "test-os 1.0",
  sdkVersion: "0.0.0",
  target: { name: "system", providerId: "local.apple.speech" },
  requestedLocale: ["de-DE"],
  resolvedLocale: ["de-DE"],
  locality: "on_device",
  samples: [{ ...sample }],
  skipped: [],
  p50: structuredClone(stats),
  p95: structuredClone(stats)
});

describe("speech benchmark report schema", () => {
  it("compiles the schema", () => {
    expect(typeof compile()).toBe("function");
  });

  it("accepts a minimal report", () => {
    expect(validate(minimalReport()), errorsOf()).toBe(true);
  });

  it.each(["sdk_tests", "ios_device_bench", "web_voices_lab"])("accepts harness %s", (harness) => {
    const report = minimalReport();
    report.harness = harness;
    expect(validate(report), errorsOf()).toBe(true);
  });

  it("accepts a report with no samples, every scenario skipped", () => {
    const report = minimalReport();
    report.requestedLocale = [];
    report.resolvedLocale = [];
    report.samples = [];
    report.skipped = [
      "first_call_cold",
      "first_call_after_prepare",
      "repeat_same_voice",
      "switch_language",
      "speak_after_stop",
      "text_length",
      "render_speed"
    ].map((scenario) => ({ scenario, reason: "no streaming delivery" }));
    report.p50 = [];
    report.p95 = [];
    expect(validate(report), errorsOf()).toBe(true);
  });

  const rejected: Array<[string, (report: Report) => void]> = [
    ["a different schema version", (r) => (r.schema = "inderun-speech-benchmark/2")],
    ["an unknown harness", (r) => (r.harness = "xcode")],
    ["a negative metric", (r) => (r.samples[0].renderMs = -1)],
    ["a sample without utteranceId", (r) => delete r.samples[0].utteranceId],
    ["an unknown sample key", (r) => (r.samples[0].text = "hello")],
    ["a missing skipped list", (r) => delete r.skipped],
    ["a string requestedLocale", (r) => (r.requestedLocale = "de-DE")],
    ["duplicate resolved locales", (r) => (r.resolvedLocale = ["de-DE", "de-DE"])]
  ];
  it.each(rejected)("rejects %s", (_name, mutate) => {
    const report = minimalReport();
    mutate(report);
    expect(validate(report)).toBe(false);
  });

  it("every committed report validates and names corpus utterances", () => {
    const corpus = readJson(`${fixturesDir}utterance-corpus.json`) as {
      utterances: Array<{ id: string }>;
      extendedUtterances?: Array<{ id: string }>;
    };
    const known = new Set(
      [...corpus.utterances, ...(corpus.extendedUtterances ?? [])].map((entry) => entry.id)
    );
    const files = readdirSync(reportsDir).filter((name) => name.endsWith(".json"));
    for (const file of files) {
      const report = readJson(`${reportsDir}${file}`) as {
        samples: Array<{ utteranceId: string }>;
      };
      expect(validate(report), `${file}: ${errorsOf()}`).toBe(true);
      for (const entry of report.samples)
        expect(known, `${file}: ${entry.utteranceId}`).toContain(entry.utteranceId);
    }
  });
});
