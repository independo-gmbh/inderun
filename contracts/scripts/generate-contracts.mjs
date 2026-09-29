import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import {
  collectEnumWireParityProblems,
  kotlinEnumConstantName,
  kotlinEnumName,
  kotlinEnumOverrides,
  parseKotlinXEnums
} from "./kotlin-enum-wire-values.mjs";

const execFileAsync = promisify(execFile);

const contractsRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(contractsRoot);
const packageRoot = join(repoRoot, "packages", "contracts");
const schemasDir = join(contractsRoot, "schemas");
const generatedDir = join(packageRoot, "src", "generated");
const swiftContractsPath = join(
  repoRoot,
  "ios",
  "IndeRun",
  "Sources",
  "IndeRunContracts",
  "Contracts.swift"
);
const kotlinContractsPath = join(
  repoRoot,
  "android",
  "inderun-contracts",
  "src",
  "main",
  "kotlin",
  "app",
  "independo",
  "inderun",
  "contracts",
  "Contracts.kt"
);
const rustContractsPath = join(
  repoRoot,
  "rust",
  "inderun-route-core",
  "src",
  "generated",
  "contracts.rs"
);

const schemas = [
  {
    input: "task-request.schema.json",
    typeOutput: "task-request.ts",
    constName: "taskRequestSchema"
  },
  {
    input: "task-result.schema.json",
    typeOutput: "task-result.ts",
    constName: "taskResultSchema"
  },
  {
    input: "inderun-error.schema.json",
    typeOutput: "inderun-error.ts",
    constName: "inderunErrorSchema"
  },
  {
    input: "http-request.schema.json",
    typeOutput: "http-request.ts",
    constName: "httpRequestSchema"
  },
  {
    input: "http-response.schema.json",
    typeOutput: "http-response.ts",
    constName: "httpResponseSchema"
  },
  {
    input: "telemetry-event.schema.json",
    typeOutput: "telemetry-event.ts",
    constName: "telemetryEventSchema"
  },
  {
    input: "route-planner-input.schema.json",
    typeOutput: "route-planner-input.ts",
    constName: "routePlannerInputSchema"
  },
  {
    input: "route-plan.schema.json",
    typeOutput: "route-plan.ts",
    constName: "routePlanSchema"
  },
  {
    input: "model-package.schema.json",
    typeOutput: "model-package.ts",
    constName: "modelPackageSchema"
  },
  {
    input: "stream-run.schema.json",
    typeOutput: "stream-run.ts",
    constName: "streamRunSchema"
  },
  {
    input: "stream-event.schema.json",
    typeOutput: "stream-event.ts",
    constName: "streamEventSchema"
  },
  {
    input: "stream-terminal-outcome.schema.json",
    typeOutput: "stream-terminal-outcome.ts",
    constName: "streamTerminalOutcomeSchema"
  }
];

await mkdir(generatedDir, { recursive: true });

const schemaExports = [];
for (const schema of schemas) {
  const raw = await readFile(join(schemasDir, schema.input), "utf8");
  schemaExports.push(
    `export const ${schema.constName} = ${JSON.stringify(JSON.parse(raw), null, 2)} as const;`
  );
}

await writeFile(
  join(generatedDir, "schemas.ts"),
  `/* This file was generated from JSON Schema. Do not edit by hand. */\n\n${schemaExports.join(
    "\n\n"
  )}\n`
);

await writeFile(
  join(generatedDir, "index.ts"),
  `/* This file was generated from JSON Schema. Do not edit by hand. */\n\n${(
    await Promise.all(
      schemas.map(async (schema) => {
        const schemaJson = JSON.parse(await readFile(join(schemasDir, schema.input), "utf8"));
        if (!schemaJson.title) {
          throw new Error(`${schema.input} is missing a title for TypeScript index generation.`);
        }
        return `export type { ${schemaJson.title} } from "./${basename(schema.typeOutput, ".ts")}.js";`;
      })
    )
  ).join("\n")}\nexport * from "./schemas.js";\n`
);

function quicktypeBinary() {
  return join(
    repoRoot,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "quicktype.cmd" : "quicktype"
  );
}

async function generateTypeScriptContracts() {
  for (const schema of schemas) {
    const schemaPath = join(schemasDir, schema.input);
    const schemaJson = JSON.parse(await readFile(schemaPath, "utf8"));
    if (!schemaJson.title) {
      throw new Error(`${schema.input} is missing a title for TypeScript code generation.`);
    }

    const outputPath = join(generatedDir, schema.typeOutput);
    await execFileAsync(quicktypeBinary(), [
      "--lang",
      "ts",
      "--src-lang",
      "schema",
      "--just-types",
      "--prefer-unions",
      "--prefer-types",
      "--prefer-const-values",
      "--acronym-style",
      "original",
      "-t",
      schemaJson.title,
      schemaPath,
      "--out",
      outputPath
    ]);

    const generatedSource = await readFile(outputPath, "utf8");
    const normalizedSource = generatedSource
      .replaceAll("[property: string]: any;", "[property: string]: unknown;")
      .replaceAll("{ [key: string]: any }", "{ [key: string]: unknown }");
    await writeFile(
      outputPath,
      `/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */\n\n${normalizedSource}`
    );
  }
}

function replaceExactly(source, replacements) {
  let output = source;
  for (const [from, to] of replacements) {
    if (!output.includes(from)) {
      throw new Error(`Expected Kotlin normalization pattern not found:\n${from}`);
    }
    output = output.replaceAll(from, to);
  }
  return output;
}

function normalizeKotlinMessageClass(source) {
  return source.replace(
    /data class Message \(\n(?:\s*\/\*\*[\s\S]*?\*\/\n\s*val (?:role|content):[^\n]+,?\n){2}\)/m,
    `data class Message (
    /**
     * Role of the message author.
     */
    val role: MessageRole,

    /**
     * Text content for this message.
     */
    val content: String
)`
  );
}

/**
 * Renders a Kotlin string literal. Kotlin reads `$` as the start of a template
 * expression, so it is escaped alongside the usual backslash and quote.
 *
 * @param {string} value Value the literal must denote.
 * @returns {string} Quoted Kotlin string literal.
 */
function kotlinStringLiteral(value) {
  const escaped = value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("$", "\\$");
  return `"${escaped}"`;
}

/**
 * Rewrites every bare `enum class X { A, B }` quicktype's plain Kotlin renderer emits
 * into one that carries its schema wire value, plus the reverse lookup Swift gets for
 * free from `RawRepresentable`:
 *
 *     enum class Phase(val rawValue: String) {
 *         ProviderSelected("provider_selected"),
 *         Started("started"),
 *         ;
 *
 *         companion object {
 *             fun fromRawValue(value: String): Phase? = entries.firstOrNull { it.rawValue == value }
 *         }
 *     }
 *
 * One rule for every enum: the wire value is never optional and never hand-written.
 * `kotlinEnumOverrides` only renames the type or its entries, so which enums get a
 * `rawValue` is not a per-enum decision (issue #212).
 *
 * @param {string} source Generated Kotlin source from the plain (`--just-types`) renderer.
 * @param {Map<string, Array<{ constant: string, wire: string }>>} wireValues Per-enum
 *   wire values from the kotlinx renderer, keyed by quicktype's enum name.
 * @returns {string} Kotlin source whose enums all expose their wire value.
 */
function rewriteKotlinEnums(source, wireValues) {
  const rewritten = new Set();

  const output = source.replace(
    /^enum class (\w+) \{\n((?: {4}\w+,?\n)+)\}$/gm,
    (_match, quicktypeName, body) => {
      const entries = wireValues.get(quicktypeName);
      if (entries === undefined) {
        throw new Error(
          `The kotlinx quicktype run emitted no wire values for enum ${quicktypeName}.`
        );
      }

      // The two Kotlin renderers share KotlinRenderer's enum-case namer, including its
      // keyword avoidance (`system` becomes `RoleSystem`). Pairing the runs up by
      // position is only sound while that holds, so assert it rather than assume it.
      const declared = body
        .trimEnd()
        .split("\n")
        .map((line) => line.trim().replace(/,$/, ""));
      const named = entries.map((entry) => entry.constant);
      if (declared.join(",") !== named.join(",")) {
        throw new Error(
          `quicktype's Kotlin renderers disagree on the entries of enum ${quicktypeName}:\n` +
            `  --just-types:        ${declared.join(", ")}\n` +
            `  --framework kotlinx: ${named.join(", ")}`
        );
      }

      rewritten.add(quicktypeName);
      const kotlinName = kotlinEnumName(quicktypeName);
      const constants = entries
        .map(
          ({ constant, wire }) =>
            `    ${kotlinEnumConstantName(quicktypeName, constant)}(${kotlinStringLiteral(wire)}),`
        )
        .join("\n");

      return `enum class ${kotlinName}(val rawValue: String) {
${constants}
    ;

    companion object {
        fun fromRawValue(value: String): ${kotlinName}? = entries.firstOrNull { it.rawValue == value }
    }
}`;
    }
  );

  const unusedOverrides = Object.keys(kotlinEnumOverrides).filter(
    (quicktypeName) => !rewritten.has(quicktypeName)
  );
  if (unusedOverrides.length > 0) {
    throw new Error(
      `kotlinEnumOverrides names enums quicktype no longer emits: ${unusedOverrides.join(", ")}`
    );
  }

  const bare = [...output.matchAll(/^enum class (\w+) \{$/gm)].map(([, name]) => name);
  if (bare.length > 0) {
    throw new Error(`Generated Kotlin enums left without a wire value: ${bare.join(", ")}`);
  }

  return output;
}

function normalizeKotlinContractsSource(source, wireValues) {
  let output = `/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */\n\n${source}`;

  output = replaceExactly(output, [
    ["data class HTTPRequest (", "data class HttpRequest ("],
    ["data class HTTPResponse (", "data class HttpResponse ("],
    ["val role: Role", "val role: MessageRole"],
    ["val kind: Kind", "val kind: TaskKind = TaskKind.TEXT_TO_TEXT"],
    ["val level: Level? = null", "val level: TelemetryLevel? = null"],
    ["val errorClass: ErrorClass? = null", "val errorClass: IndeRunErrorClass? = null"],
    ["val errorClass: ErrorClass,", "val errorClass: IndeRunErrorClass,"],
    ["val type: OutputType", "val type: OutputType = OutputType.TEXT"]
  ]);

  output = normalizeKotlinMessageClass(output);

  output = output.replace(
    /val schemaVersion: SchemaVersion,\n(\s*\/\*\*\n\s*\* Task descriptor used by routing and provider capability matching\.\n\s*\*\/\n\s*val task: TaskRequestTask),/m,
    `val schemaVersion: SchemaVersion = SchemaVersion.V1_0,\n$1 = TaskRequestTask(),`
  );
  output = output.replace(
    /val schemaVersion: SchemaVersion,\n(\s*\/\*\*\n\s*\* Required minimal telemetry summary attached to every result\.\n\s*\*\/\n\s*val telemetry: TaskResultTelemetry),/m,
    `val schemaVersion: SchemaVersion = SchemaVersion.V1_0,\n$1,`
  );
  output = output.replace(
    /val schemaVersion: SchemaVersion\n\)/g,
    "val schemaVersion: SchemaVersion = SchemaVersion.V1_0\n)"
  );

  output = rewriteKotlinEnums(output, wireValues);

  return `${output}\n`;
}

const kotlinQuicktypeArgs = [
  "--lang",
  "kotlin",
  "--src-lang",
  "schema",
  "--acronym-style",
  "original",
  "--package",
  "app.independo.inderun.contracts"
];

/**
 * Collects the schema wire value of every Kotlin enum from a throwaway second
 * quicktype run.
 *
 * The shipped file is generated with `--just-types`, whose renderer drops the JSON
 * value (`enum class Phase { ProviderSelected, Started }`) — the defect in issue #212.
 * The kotlinx renderer is the one Kotlin renderer that keeps it, but its output cannot
 * be shipped: it annotates every class with `@Serializable`/`@SerialName`, which would
 * put kotlinx.serialization on the published `:inderun-contracts` POM. So it is
 * rendered to a temp file and read for its enums alone.
 *
 * Reading the values back out of quicktype rather than deriving them from the schemas
 * keeps quicktype the single authority on which Kotlin entry name belongs to which
 * schema value, including its keyword avoidance and acronym styling.
 *
 * @param {string} tempDir Scratch directory for the throwaway render.
 * @returns {Promise<Map<string, Array<{ constant: string, wire: string }>>>} Per-enum
 *   entries, keyed by quicktype's enum name.
 */
async function readKotlinEnumWireValues(tempDir) {
  // No `--just-types` here: quicktype's renderer factory lets it win over `--framework`.
  const quicktypeOutputPath = join(tempDir, "ContractsKotlinX.kt");
  await execFileAsync(quicktypeBinary(), [
    ...kotlinQuicktypeArgs,
    "--framework",
    "kotlinx",
    ...schemas.map((schema) => join(schemasDir, schema.input)),
    "--out",
    quicktypeOutputPath
  ]);

  return parseKotlinXEnums(await readFile(quicktypeOutputPath, "utf8"));
}

async function generateKotlinContracts(tempDir) {
  const quicktypeOutputPath = join(tempDir, "Contracts.kt");

  await execFileAsync(quicktypeBinary(), [
    ...kotlinQuicktypeArgs,
    "--just-types",
    ...schemas.map((schema) => join(schemasDir, schema.input)),
    "--out",
    quicktypeOutputPath
  ]);

  const kotlinSource = normalizeKotlinContractsSource(
    await readFile(quicktypeOutputPath, "utf8"),
    await readKotlinEnumWireValues(tempDir)
  );

  await mkdir(dirname(kotlinContractsPath), { recursive: true });
  await writeFile(kotlinContractsPath, kotlinSource);

  return kotlinSource;
}

// The Rust shared route-planning core only consumes the route-planner contracts,
// so it is generated from just those two schemas (unlike the other languages,
// which bind the full contract surface).
const rustSchemaInputs = ["route-planner-input.schema.json", "route-plan.schema.json"];

async function generateRustContracts(tempDir) {
  const quicktypeOutputPath = join(tempDir, "contracts.rs");

  await execFileAsync(quicktypeBinary(), [
    "--lang",
    "rust",
    "--src-lang",
    "schema",
    "--density",
    "normal",
    "--visibility",
    "public",
    "--derive-debug",
    "--derive-clone",
    "--derive-partial-eq",
    "--no-leading-comments",
    ...rustSchemaInputs.map((input) => join(schemasDir, input)),
    "--out",
    quicktypeOutputPath
  ]);

  const rustSource = await readFile(quicktypeOutputPath, "utf8");

  await mkdir(dirname(rustContractsPath), { recursive: true });
  await writeFile(
    rustContractsPath,
    `/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */\n\n${rustSource}`
  );

  // Normalize to rustfmt output so `cargo fmt --check` passes on the committed file.
  try {
    await execFileAsync("rustfmt", ["--edition", "2024", rustContractsPath]);
  } catch (error) {
    throw new Error(
      `rustfmt is required to generate the committed Rust contracts (${rustContractsPath}). ` +
        `Install the Rust toolchain (https://rustup.rs) and ensure rustfmt is on PATH.`,
      { cause: error }
    );
  }
}

function replaceAll(source, replacements) {
  let output = source;
  for (const [from, to] of replacements) {
    output = output.replaceAll(from, to);
  }
  return output;
}

function addJSONAnyValueInitializer(source) {
  return source.replace(
    "public class JSONAny: Codable {\n\n    public let value: Any",
    `public class JSONAny: Codable {

    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }`
  );
}

/**
 * Replaces quicktype's deprecated Swift `JSONNull.hashValue` implementation
 * with the modern `hash(into:)` Hashable requirement.
 *
 * @param {string} source Generated Swift contract source.
 * @returns {string} Swift source with warning-free JSONNull Hashable conformance.
 */
function updateJSONNullHashableConformance(source) {
  return source.replace(
    `    public var hashValue: Int {
            return 0
    }`,
    `    public func hash(into hasher: inout Hasher) {
            hasher.combine(0)
    }`
  );
}

const tempDir = await mkdtemp(join(tmpdir(), "inderun-quicktype-"));
const quicktypeOutputPath = join(tempDir, "Contracts.swift");

try {
  await generateTypeScriptContracts();
  const kotlinSource = await generateKotlinContracts(tempDir);
  await generateRustContracts(tempDir);

  await execFileAsync(quicktypeBinary(), [
    "--lang",
    "swift",
    "--src-lang",
    "schema",
    "--initializers",
    "--access-level",
    "public",
    "--sendable",
    "--mutable-properties",
    "--acronym-style",
    "original",
    ...schemas.map((schema) => join(schemasDir, schema.input)),
    "--out",
    quicktypeOutputPath
  ]);

  let swiftSource = await readFile(quicktypeOutputPath, "utf8");
  swiftSource = addJSONAnyValueInitializer(swiftSource);
  swiftSource = updateJSONNullHashableConformance(swiftSource);
  swiftSource = replaceAll(swiftSource, [
    ["HTTPRequest", "HttpRequest"],
    ["HTTPResponse", "HttpResponse"],
    ['case authError = "AuthError"', 'case AuthError = "AuthError"'],
    [
      'case capabilityMismatch = "CapabilityMismatch"',
      'case CapabilityMismatch = "CapabilityMismatch"'
    ],
    ['case errorClassInternal = "Internal"', 'case Internal = "Internal"'],
    ['case offline = "Offline"', 'case Offline = "Offline"'],
    ['case rateLimited = "RateLimited"', 'case RateLimited = "RateLimited"'],
    ['case timeout = "Timeout"', 'case Timeout = "Timeout"'],
    ['case unavailable = "Unavailable"', 'case Unavailable = "Unavailable"'],
    ['case methodGET = "GET"', 'case get = "GET"']
  ]);

  await writeFile(swiftContractsPath, swiftSource);

  // Kotlin and Swift are generated from the same schemas, so a wire value one of them
  // carries and the other does not is a generator defect, not a platform difference.
  // Checked here so `pnpm generate:code` can never emit a divergent pair; the same
  // comparison runs against the committed files in verify-enum-wire-parity.mjs.
  const parityProblems = collectEnumWireParityProblems(kotlinSource, swiftSource);
  if (parityProblems.length > 0) {
    throw new Error(
      `Kotlin and Swift disagree on generated enum wire values:\n\n${parityProblems.join("\n")}`
    );
  }
} finally {
  await rm(tempDir, { recursive: true, force: true });
}
