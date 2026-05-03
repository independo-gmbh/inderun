import { compileFromFile } from "json-schema-to-typescript";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const schemasDir = join(root, "schemas");
const generatedDir = join(root, "src", "generated");

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
  }
];

await mkdir(generatedDir, { recursive: true });

for (const schema of schemas) {
  const schemaPath = join(schemasDir, schema.input);
  const typeSource = await compileFromFile(schemaPath, {
    bannerComment:
      "/* This file was generated from JSON Schema. Do not edit by hand. */",
    cwd: root,
    style: {
      printWidth: 100,
      semi: true,
      singleQuote: false,
      tabWidth: 2,
      trailingComma: "none"
    }
  });
  await writeFile(join(generatedDir, schema.typeOutput), typeSource);
}

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
  `/* This file was generated from JSON Schema. Do not edit by hand. */\n\n${schemas
    .map((schema) => `export type * from "./${basename(schema.typeOutput, ".ts")}.js";`)
    .join("\n")}\nexport * from "./schemas.js";\n`
);
