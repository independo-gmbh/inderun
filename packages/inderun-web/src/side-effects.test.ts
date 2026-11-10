import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { describe, expect, it } from "vitest";

/**
 * `package.json` declares `"sideEffects": false`, which lets a bundler drop every module of this
 * package whose exports an app does not use: importing only `speak` from the package root then
 * leaves out the engine, the providers and the WASM route-core loader. That promise holds only while
 * no module does anything when it is imported, so this test reads every published source file and
 * fails on a top-level statement that could: a call, an assignment, a bare `import "x"`, or a
 * variable initialized by anything but a literal, a function, or a fresh `Map`/`Set`/`WeakMap`/
 * `WeakSet`/`Symbol` the module keeps to itself.
 *
 * If a module genuinely needs an import-time effect, list it under `sideEffects` in `package.json`
 * (an array of files) instead of `false`, and allow it here.
 */

const SRC = fileURLToPath(new URL(".", import.meta.url));
const MODULE_STATE_CONSTRUCTORS = new Set(["Map", "Set", "WeakMap", "WeakSet"]);

function publishedSources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "test" ? [] : publishedSources(path);
    return entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts") ? [path] : [];
  });
}

function isInert(node: ts.Expression | undefined): boolean {
  if (node === undefined) return true;
  if (
    ts.isLiteralExpression(node) ||
    ts.isNoSubstitutionTemplateLiteral(node) ||
    ts.isArrowFunction(node) ||
    ts.isFunctionExpression(node) ||
    ts.isClassExpression(node) ||
    ts.isIdentifier(node)
  ) {
    return true;
  }
  switch (node.kind) {
    case ts.SyntaxKind.TrueKeyword:
    case ts.SyntaxKind.FalseKeyword:
    case ts.SyntaxKind.NullKeyword:
      return true;
  }
  if (
    ts.isAsExpression(node) ||
    ts.isSatisfiesExpression(node) ||
    ts.isParenthesizedExpression(node) ||
    ts.isTypeAssertionExpression(node)
  ) {
    return isInert(node.expression);
  }
  if (ts.isPropertyAccessExpression(node)) return isInert(node.expression);
  if (ts.isPrefixUnaryExpression(node)) return isInert(node.operand);
  if (ts.isBinaryExpression(node)) return isInert(node.left) && isInert(node.right);
  if (ts.isTemplateExpression(node)) return node.templateSpans.every((s) => isInert(s.expression));
  if (ts.isArrayLiteralExpression(node)) return node.elements.every(isInert);
  if (ts.isObjectLiteralExpression(node)) {
    return node.properties.every((property) =>
      ts.isPropertyAssignment(property)
        ? isInert(property.initializer)
        : ts.isSpreadAssignment(property)
          ? isInert(property.expression)
          : true
    );
  }
  if (ts.isNewExpression(node) && ts.isIdentifier(node.expression)) {
    return (
      MODULE_STATE_CONSTRUCTORS.has(node.expression.text) && (node.arguments ?? []).every(isInert)
    );
  }
  if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)) {
    return node.expression.text === "Symbol" && node.arguments.every(isInert);
  }
  return false;
}

function importTimeEffects(file: string): string[] {
  const source = ts.createSourceFile(
    file,
    readFileSync(file, "utf8"),
    ts.ScriptTarget.Latest,
    true
  );
  const found: string[] = [];
  const report = (node: ts.Node) => {
    const line = source.getLineAndCharacterOfPosition(node.getStart()).line + 1;
    found.push(`${relative(SRC, file)}:${line}: ${node.getText().split("\n")[0]}`);
  };
  for (const statement of source.statements) {
    if (ts.isImportDeclaration(statement)) {
      if (statement.importClause === undefined) report(statement);
    } else if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (!isInert(declaration.initializer)) report(declaration);
      }
    } else if (ts.isClassDeclaration(statement)) {
      for (const member of statement.members) {
        const isStatic = ts.canHaveModifiers(member)
          ? (ts.getModifiers(member) ?? []).some((m) => m.kind === ts.SyntaxKind.StaticKeyword)
          : false;
        if (ts.isClassStaticBlockDeclaration(member)) report(member);
        else if (ts.isPropertyDeclaration(member) && isStatic && !isInert(member.initializer)) {
          report(member);
        }
      }
    } else if (
      !ts.isExportDeclaration(statement) &&
      !ts.isFunctionDeclaration(statement) &&
      !ts.isInterfaceDeclaration(statement) &&
      !ts.isTypeAliasDeclaration(statement) &&
      !ts.isEnumDeclaration(statement) &&
      !ts.isModuleDeclaration(statement)
    ) {
      report(statement);
    }
  }
  return found;
}

describe('"sideEffects": false', () => {
  it("is declared in package.json", () => {
    const manifest = JSON.parse(readFileSync(join(SRC, "..", "package.json"), "utf8")) as {
      sideEffects?: unknown;
    };
    expect(manifest.sideEffects).toBe(false);
  });

  it("holds: no published module does anything when it is imported", () => {
    const files = publishedSources(SRC);
    expect(files.length).toBeGreaterThan(0);
    expect(files.flatMap(importTimeEffects)).toEqual([]);
  });
});
