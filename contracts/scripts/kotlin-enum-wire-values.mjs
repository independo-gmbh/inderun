/**
 * Shared vocabulary for the wire values of the generated Kotlin contract enums.
 *
 * `generate-contracts.mjs` emits them, `verify-enum-wire-parity.mjs` checks the
 * committed output against Swift, and both need the same two things: the table of
 * enums whose Kotlin spelling deviates from quicktype's default, and one parser per
 * source format. Keeping them here means a rename is recorded once.
 */

/**
 * Generated Kotlin enums that deviate from quicktype's default output, keyed by
 * quicktype's own enum name — which is also the Swift enum name, so the key doubles
 * as the Kotlin/Swift pairing for the parity check.
 *
 * `kotlinName` renames the type, `constants` renames individual entries. Both only
 * preserve spellings the published Kotlin API already has; the wire values always
 * come from the schema via quicktype, never from this table.
 */
export const kotlinEnumOverrides = {
  Role: {
    kotlinName: "MessageRole",
    constants: { Assistant: "ASSISTANT", RoleSystem: "SYSTEM", User: "USER" }
  },
  Kind: {
    kotlinName: "TaskKind",
    constants: { TextToText: "TEXT_TO_TEXT" }
  },
  Level: {
    kotlinName: "TelemetryLevel",
    constants: { Debug: "DEBUG", Minimal: "MINIMAL", Off: "OFF" }
  },
  ErrorClass: {
    kotlinName: "IndeRunErrorClass"
  },
  SchemaVersion: {
    constants: { The10: "V1_0" }
  },
  FinishReason: {
    constants: { Cancelled: "CANCELLED", Error: "ERROR", Length: "LENGTH", Stop: "STOP" }
  },
  OutputType: {
    constants: { Text: "TEXT" }
  }
};

/**
 * The Kotlin type name a generated enum ends up with.
 *
 * @param {string} quicktypeName Enum name as quicktype emits it.
 * @returns {string} Kotlin type name in the committed contracts.
 */
export function kotlinEnumName(quicktypeName) {
  return kotlinEnumOverrides[quicktypeName]?.kotlinName ?? quicktypeName;
}

/**
 * Inverse of {@link kotlinEnumName}: maps a committed Kotlin enum name back to the
 * quicktype/Swift name, so the two languages' enums can be paired up.
 *
 * @returns {Map<string, string>} Kotlin type name to quicktype/Swift name.
 */
export function swiftNamesByKotlinName() {
  const names = new Map();
  for (const [quicktypeName, override] of Object.entries(kotlinEnumOverrides)) {
    if (override.kotlinName !== undefined) {
      names.set(override.kotlinName, quicktypeName);
    }
  }
  return names;
}

/**
 * The Kotlin entry name a generated enum case ends up with.
 *
 * @param {string} quicktypeName Enum name as quicktype emits it.
 * @param {string} constant Entry name as quicktype emits it.
 * @returns {string} Entry name in the committed contracts.
 */
export function kotlinEnumConstantName(quicktypeName, constant) {
  return kotlinEnumOverrides[quicktypeName]?.constants?.[constant] ?? constant;
}

/**
 * Parses the enums of a quicktype `--framework kotlinx` run, whose renderer is the
 * only Kotlin one that carries the JSON value:
 *
 *     enum class Phase(val value: String) {
 *         @SerialName("provider_selected") ProviderSelected("provider_selected"),
 *         @SerialName("started") Started("started");
 *     }
 *
 * @param {string} source Generated Kotlin source from the kotlinx renderer.
 * @returns {Map<string, Array<{ constant: string, wire: string }>>} Enum name to entries.
 */
export function parseKotlinXEnums(source) {
  const enums = new Map();
  const blocks = source.matchAll(/^enum class (\w+)\(val value: String\) \{\n([\s\S]*?)^\}$/gm);
  for (const [, name, body] of blocks) {
    const entries = [];
    for (const line of body.split("\n")) {
      const entry = line
        .trim()
        .match(/^@SerialName\("((?:[^"\\]|\\.)*)"\) (\w+)\("(?:[^"\\]|\\.)*"\)[,;]?$/);
      if (entry !== null) {
        entries.push({ constant: entry[2], wire: unescapeKotlin(entry[1]) });
      }
    }
    enums.set(name, entries);
  }
  return enums;
}

/**
 * Parses the enums of the committed Kotlin contracts, which carry their wire value as
 * a `rawValue` constructor argument. A bare `enum class X {` (no `rawValue`) is
 * reported as such rather than skipped — that shape is the defect this file exists to
 * keep out of the output.
 *
 * @param {string} source Committed Kotlin contract source.
 * @returns {{ enums: Map<string, Array<{ constant: string, wire: string }>>, bare: string[] }}
 */
export function parseKotlinEnums(source) {
  const enums = new Map();
  const blocks = source.matchAll(/^enum class (\w+)\(val rawValue: String\) \{\n([\s\S]*?)^\}$/gm);
  for (const [, name, body] of blocks) {
    const entries = [];
    for (const line of body.split("\n")) {
      const entry = line.trim().match(/^(\w+)\("((?:[^"\\]|\\.)*)"\),?$/);
      if (entry !== null) {
        entries.push({ constant: entry[1], wire: unescapeKotlin(entry[2]) });
      }
    }
    enums.set(name, entries);
  }

  const bare = [...source.matchAll(/^enum class (\w+) \{$/gm)].map(([, name]) => name);
  return { enums, bare };
}

/**
 * Parses the top-level string-backed enums of the committed Swift contracts. The
 * `Codable, Sendable` conformance list is what separates them from the nested
 * `CodingKeys` enums, which are property-name maps rather than contract values.
 *
 * @param {string} source Committed Swift contract source.
 * @returns {Map<string, Array<{ constant: string, wire: string }>>} Enum name to cases.
 */
export function parseSwiftEnums(source) {
  const enums = new Map();
  const blocks = source.matchAll(
    /^public enum (\w+): String, Codable, Sendable \{\n([\s\S]*?)^\}$/gm
  );
  for (const [, name, body] of blocks) {
    const cases = [];
    for (const line of body.split("\n")) {
      const swiftCase = line.trim().match(/^case (\w+) = "((?:[^"\\]|\\.)*)"$/);
      if (swiftCase !== null) {
        cases.push({ constant: swiftCase[1], wire: swiftCase[2].replaceAll('\\"', '"') });
      }
    }
    enums.set(name, cases);
  }
  return enums;
}

/**
 * Kotlin string literals escape `$` (it opens a template expression) and `"`. Both are
 * quicktype's own escaping, undone here so wire values compare equal across languages.
 *
 * @param {string} literal Contents of a Kotlin string literal.
 * @returns {string} The value the literal denotes.
 */
function unescapeKotlin(literal) {
  return literal.replaceAll('\\"', '"').replaceAll("\\$", "$");
}

/**
 * Compares the wire values the Kotlin and Swift contracts carry for the same schema
 * enum. Constant names deliberately are not compared — quicktype styles them per
 * language and prefixes differently on keyword collisions (`system` becomes
 * `RoleSystem` in Kotlin, `cloudRequired` in Swift's `Cloud`) — so the assertion is
 * that both languages spell the same set of *wire* values for the same enum.
 *
 * @param {string} kotlinSource Committed or freshly generated Kotlin contract source.
 * @param {string} swiftSource Committed or freshly generated Swift contract source.
 * @returns {string[]} One message per divergence; empty when the two agree.
 */
export function collectEnumWireParityProblems(kotlinSource, swiftSource) {
  const problems = [];
  const { enums: kotlinEnums, bare } = parseKotlinEnums(kotlinSource);
  const swiftEnums = parseSwiftEnums(swiftSource);
  const swiftNames = swiftNamesByKotlinName();

  for (const name of bare) {
    problems.push(
      `Kotlin enum ${name} has no rawValue: its schema wire values are unreachable from Kotlin.`
    );
  }

  const pairedSwiftNames = new Set();
  for (const [kotlinName, kotlinEntries] of kotlinEnums) {
    const swiftName = swiftNames.get(kotlinName) ?? kotlinName;
    const swiftCases = swiftEnums.get(swiftName);
    if (swiftCases === undefined) {
      problems.push(`Kotlin enum ${kotlinName} has no Swift counterpart ${swiftName}.`);
      continue;
    }

    pairedSwiftNames.add(swiftName);
    const kotlinWire = kotlinEntries.map((entry) => entry.wire).sort();
    const swiftWire = swiftCases.map((swiftCase) => swiftCase.wire).sort();
    if (kotlinWire.join("\u0000") !== swiftWire.join("\u0000")) {
      problems.push(
        `Wire values disagree for ${kotlinName} (Swift ${swiftName}):\n` +
          `  Kotlin: ${JSON.stringify(kotlinWire)}\n` +
          `  Swift:  ${JSON.stringify(swiftWire)}`
      );
    }
  }

  for (const swiftName of swiftEnums.keys()) {
    if (!pairedSwiftNames.has(swiftName)) {
      problems.push(`Swift enum ${swiftName} has no Kotlin counterpart.`);
    }
  }

  return problems;
}
