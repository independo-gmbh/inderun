import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

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
    output = output.replace(from, to);
  }
  return output;
}

function normalizeKotlinContractsSource(source) {
  let output = `/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */\n\n${source}`;

  output = replaceExactly(output, [
    ["data class HTTPRequest (", "data class HttpRequest ("],
    ["data class HTTPResponse (", "data class HttpResponse ("],
    ["val role: Role", "val role: MessageRole"],
    ["val execution: Execution", "val execution: ExecutionPolicy"],
    ["val kind: Kind", "val kind: TaskKind = TaskKind.TEXT_TO_TEXT"],
    ["val level: Level? = null", "val level: TelemetryLevel? = null"],
    ["val errorClass: ErrorClass? = null", "val errorClass: IndeRunErrorClass? = null"],
    ["val errorClass: ErrorClass,", "val errorClass: IndeRunErrorClass,"],
    ["val type: OutputType", "val type: OutputType = OutputType.TEXT"],
    ["val schemaVersion: SchemaVersion,\n\n    /**\n     * Task descriptor used by routing and provider capability matching.\n     */\n    val task: Task,",
      "val schemaVersion: SchemaVersion = SchemaVersion.V1_0,\n\n    /**\n     * Task descriptor used by routing and provider capability matching.\n     */\n    val task: Task = Task(),"],
    ["val schemaVersion: SchemaVersion,\n\n    /**\n     * Required minimal telemetry summary attached to every result.\n     */\n    val telemetry: TaskResultTelemetry,",
      "val schemaVersion: SchemaVersion = SchemaVersion.V1_0,\n\n    /**\n     * Required minimal telemetry summary attached to every result.\n     */\n    val telemetry: TaskResultTelemetry,"],
    ["val schemaVersion: SchemaVersion\n)", "val schemaVersion: SchemaVersion = SchemaVersion.V1_0\n)"],
    [`data class Message (
    /**
     * Text content for this message.
     */
    val content: String,

    /**
     * Role of the message author.
     */
    val role: MessageRole
)`, `data class Message (
    /**
     * Role of the message author.
     */
    val role: MessageRole,

    /**
     * Text content for this message.
     */
    val content: String
)`]
  ]);

  output = output.replace(
    /enum class SchemaVersion \{\s+The10\s+\}/m,
    `enum class SchemaVersion(val rawValue: String) {
    V1_0("1.0")
}`
  );
  output = output.replace(
    /enum class Kind \{\s+TextToText\s+\}/m,
    `enum class TaskKind(val rawValue: String) {
    TEXT_TO_TEXT("text_to_text")
}`
  );
  output = output.replace(
    /enum class Role \{\s+Assistant,\s+RoleSystem,\s+User\s+\}/m,
    `enum class MessageRole(val rawValue: String) {
    ASSISTANT("assistant"),
    SYSTEM("system"),
    USER("user")
}`
  );
  output = output.replace(
    /enum class Execution \{\s+Cloud,\s+OnDevice\s+\}/m,
    `enum class ExecutionPolicy(val rawValue: String) {
    CLOUD("cloud"),
    ON_DEVICE("on_device")
}`
  );
  output = output.replace(
    /enum class Level \{\s+Debug,\s+Minimal,\s+Off\s+\}/m,
    `enum class TelemetryLevel(val rawValue: String) {
    DEBUG("debug"),
    MINIMAL("minimal"),
    OFF("off")
}`
  );
  output = output.replace(
    /enum class FinishReason \{\s+Cancelled,\s+Error,\s+Length,\s+Stop\s+\}/m,
    `enum class FinishReason(val rawValue: String) {
    CANCELLED("cancelled"),
    ERROR("error"),
    LENGTH("length"),
    STOP("stop")
}`
  );
  output = output.replace(
    /enum class OutputType \{\s+Text\s+\}/m,
    `enum class OutputType(val rawValue: String) {
    TEXT("text")
}`
  );
  output = output.replace(
    /enum class ErrorClass \{\s+AuthError,\s+CapabilityMismatch,\s+Internal,\s+Offline,\s+RateLimited,\s+Timeout,\s+Unavailable\s+\}/m,
    `enum class IndeRunErrorClass(val rawValue: String) {
    AuthError("AuthError"),
    CapabilityMismatch("CapabilityMismatch"),
    Internal("Internal"),
    Offline("Offline"),
    RateLimited("RateLimited"),
    Timeout("Timeout"),
    Unavailable("Unavailable")
}`
  );

  return `${output}\n`;
}

async function generateKotlinContracts(tempDir) {
  const quicktypeOutputPath = join(tempDir, "Contracts.kt");

  await execFileAsync(quicktypeBinary(), [
    "--lang",
    "kotlin",
    "--src-lang",
    "schema",
    "--framework",
    "just-types",
    "--acronym-style",
    "original",
    "--package",
    "app.independo.inderun.contracts",
    ...schemas.map((schema) => join(schemasDir, schema.input)),
    "--out",
    quicktypeOutputPath
  ]);

  const kotlinSource = normalizeKotlinContractsSource(
    await readFile(quicktypeOutputPath, "utf8")
  );

  await mkdir(dirname(kotlinContractsPath), { recursive: true });
  await writeFile(kotlinContractsPath, kotlinSource);
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
  await generateKotlinContracts(tempDir);

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
    ['case capabilityMismatch = "CapabilityMismatch"', 'case CapabilityMismatch = "CapabilityMismatch"'],
    ['case errorClassInternal = "Internal"', 'case Internal = "Internal"'],
    ['case offline = "Offline"', 'case Offline = "Offline"'],
    ['case rateLimited = "RateLimited"', 'case RateLimited = "RateLimited"'],
    ['case timeout = "Timeout"', 'case Timeout = "Timeout"'],
    ['case unavailable = "Unavailable"', 'case Unavailable = "Unavailable"'],
    ['case methodGET = "GET"', 'case get = "GET"']
  ]);

  await writeFile(swiftContractsPath, swiftSource);
} finally {
  await rm(tempDir, { recursive: true, force: true });
}
