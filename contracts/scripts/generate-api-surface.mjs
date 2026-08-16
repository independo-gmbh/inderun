import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const contractsRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(contractsRoot);
const apiSpecPath = join(contractsRoot, "api", "inderun-api.json");

const tsOutputPath = join(
  repoRoot,
  "packages",
  "inderun-web",
  "src",
  "core",
  "generated",
  "inderun-api.ts"
);
const kotlinOutputPath = join(
  repoRoot,
  "android",
  "inderun-kotlin",
  "src",
  "main",
  "kotlin",
  "app",
  "independo",
  "inderun",
  "sdk",
  "generated",
  "IndeRunApi.kt"
);
const swiftOutputPath = join(
  repoRoot,
  "ios",
  "IndeRun",
  "Sources",
  "IndeRunSwift",
  "Generated",
  "IndeRunApi.swift"
);

const banner =
  "/* This file was generated from contracts/api/inderun-api.json. Do not edit by hand. */";

// `source: "contracts" | "core"` -> per-language import path. Hardcoded here (not
// read from the spec) to mirror generate-contracts.mjs's convention of hardcoding
// output paths in the generator rather than the spec.
//
// Note on "core"-sourced types (currently only ProviderCapabilitySnapshot): this
// generator references them by name only. Unlike "contracts"-sourced types, which
// get cross-language payload-shape parity from the separate JSON-Schema/quicktype
// pipeline (contracts/schemas/*.schema.json + generate-contracts.mjs), "core" types
// are handwritten independently per language and their shape is NOT verified to
// match across TS/Kotlin/Swift by this generator or any other check.
const tsSourceModules = {
  contracts: "@independo/inderun-contracts",
  core: "../provider.js"
};
const kotlinSourcePackages = {
  contracts: "app.independo.inderun.contracts",
  core: "app.independo.inderun.core"
};
const swiftSourceModules = {
  contracts: "IndeRunContracts",
  core: "IndeRunCore"
};

const knownOperationKeys = new Set(["description", "params", "returns", "async", "throws"]);
const knownSources = new Set(Object.keys(tsSourceModules));

// Mirrors generate-contracts.mjs's replaceExactly convention: throw with a clear,
// specific message rather than silently accepting an unsupported spec shape.
function validateSpec(spec) {
  if (spec.version !== "1.0") {
    throw new Error(`${apiSpecPath}: unsupported spec version "${spec.version}" (expected "1.0").`);
  }

  const interfaceNames = Object.keys(spec.interfaces);
  if (interfaceNames.length !== 1 || interfaceNames[0] !== "IndeRunApi") {
    throw new Error(
      `${apiSpecPath}: expected exactly one interface named "IndeRunApi", found [${interfaceNames.join(", ")}].`
    );
  }

  for (const [name, operation] of Object.entries(spec.interfaces.IndeRunApi.operations)) {
    for (const key of Object.keys(operation)) {
      if (!knownOperationKeys.has(key)) {
        throw new Error(
          `${apiSpecPath}: operation "${name}" has unknown field "${key}" (known fields: ${[...knownOperationKeys].join(", ")}).`
        );
      }
    }

    const sourcesUsed = [
      ...operation.params.map((param) => param.source),
      operation.returns.source
    ];
    for (const source of sourcesUsed) {
      if (!knownSources.has(source)) {
        throw new Error(
          `${apiSpecPath}: operation "${name}" references unknown source "${source}" (known sources: ${[...knownSources].join(", ")}).`
        );
      }
    }
  }
}

// Only params/returns feed the imports: none of the 3 target languages spell a
// checked-exception type in the signature text (TS/Kotlin have no such syntax, and
// Swift's `async throws` carries no type name), so `operation.throws` never
// contributes an import.
function typesUsedInOperation(operation) {
  return [...operation.params, operation.returns];
}

function generateTypeScript(spec) {
  const iface = spec.interfaces.IndeRunApi;
  const operationNames = Object.keys(iface.operations);

  const importsBySource = { contracts: new Set(), core: new Set() };
  for (const name of operationNames) {
    for (const type of typesUsedInOperation(iface.operations[name])) {
      importsBySource[type.source].add(type.type);
    }
  }

  const importLines = [];
  if (importsBySource.contracts.size > 0) {
    importLines.push(
      `import type { ${[...importsBySource.contracts].join(", ")} } from "${tsSourceModules.contracts}";`
    );
  }
  if (importsBySource.core.size > 0) {
    importLines.push(
      `import type { ${[...importsBySource.core].join(", ")} } from "${tsSourceModules.core}";`
    );
  }

  const methodLines = operationNames.flatMap((name) => {
    const operation = iface.operations[name];
    const params = operation.params.map((param) => `${param.name}: ${param.type}`).join(", ");
    const returnType = operation.returns.list
      ? `${operation.returns.type}[]`
      : operation.returns.type;
    const wrappedReturnType = operation.async ? `Promise<${returnType}>` : returnType;
    return [
      `  /**`,
      `   * ${operation.description}`,
      `   */`,
      `  ${name}(${params}): ${wrappedReturnType};`
    ];
  });

  return `${banner}\n\n${importLines.join("\n")}\n\nexport interface IndeRunApi {\n${methodLines.join(
    "\n"
  )}\n}\n`;
}

function generateKotlin(spec) {
  const iface = spec.interfaces.IndeRunApi;
  const operationNames = Object.keys(iface.operations);

  const importsBySource = { contracts: new Set(), core: new Set() };
  for (const name of operationNames) {
    for (const type of typesUsedInOperation(iface.operations[name])) {
      importsBySource[type.source].add(type.type);
    }
  }

  const importLines = [];
  for (const source of ["contracts", "core"]) {
    for (const type of [...importsBySource[source]].sort()) {
      importLines.push(`import ${kotlinSourcePackages[source]}.${type}`);
    }
  }

  const methodBlocks = operationNames.map((name) => {
    const operation = iface.operations[name];
    const params = operation.params.map((param) => `${param.name}: ${param.type}`).join(", ");
    const returnType = operation.returns.list
      ? `List<${operation.returns.type}>`
      : operation.returns.type;
    const modifier = operation.async ? "suspend fun" : "fun";
    return [
      `    /**`,
      `     * ${operation.description}`,
      `     */`,
      `    ${modifier} ${name}(${params}): ${returnType}`
    ].join("\n");
  });

  return `${banner}\n\npackage app.independo.inderun.sdk.generated\n\n${importLines.join(
    "\n"
  )}\n\ninterface IndeRunApi {\n${methodBlocks.join("\n\n")}\n}\n`;
}

function generateSwift(spec) {
  const iface = spec.interfaces.IndeRunApi;
  const operationNames = Object.keys(iface.operations);

  const importsBySource = { contracts: new Set(), core: new Set() };
  for (const name of operationNames) {
    for (const type of typesUsedInOperation(iface.operations[name])) {
      importsBySource[type.source].add(type.type);
    }
  }

  const importLines = [];
  if (importsBySource.contracts.size > 0) {
    importLines.push(`import ${swiftSourceModules.contracts}`);
  }
  if (importsBySource.core.size > 0) {
    importLines.push(`import ${swiftSourceModules.core}`);
  }

  const methodLines = operationNames.flatMap((name) => {
    const operation = iface.operations[name];
    const params = operation.params.map((param) => `${param.name}: ${param.type}`).join(", ");
    const returnType = operation.returns.list
      ? `[${operation.returns.type}]`
      : operation.returns.type;
    const asyncKeyword = operation.throws ? "async throws" : "async";
    return [
      `    /// ${operation.description}`,
      `    func ${name}(${params}) ${asyncKeyword} -> ${returnType}`
    ];
  });

  return `${banner}\n\n${importLines.join(
    "\n"
  )}\n\npublic protocol IndeRunApi: Sendable {\n${methodLines.join("\n")}\n}\n`;
}

const spec = JSON.parse(await readFile(apiSpecPath, "utf8"));
validateSpec(spec);

await mkdir(dirname(tsOutputPath), { recursive: true });
await writeFile(tsOutputPath, generateTypeScript(spec));

await mkdir(dirname(kotlinOutputPath), { recursive: true });
await writeFile(kotlinOutputPath, generateKotlin(spec));

await mkdir(dirname(swiftOutputPath), { recursive: true });
await writeFile(swiftOutputPath, generateSwift(spec));
