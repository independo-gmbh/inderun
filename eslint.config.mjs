import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";
import prettier from "eslint-config-prettier";

export default tseslint.config(
  {
    ignores: [
      "**/dist/**",
      "**/build/**",
      "**/.build/**",
      "**/generated/**",
      "**/node_modules/**",
      "packages/contracts/src/generated/**",
      "**/*.d.ts",
      "target/**",
      "**/.gradle-home/**"
    ]
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      globals: {
        ...globals.browser,
        ...globals.node
      }
    },
    rules: {
      // Allow intentionally-unused args/vars when prefixed with `_`.
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }
      ],
      // Pragmatic for v0.1: the generated-contract boundary and some provider
      // response parsing legitimately use `any`/loose typing.
      "@typescript-eslint/no-explicit-any": "warn"
    }
  },
  // Disable stylistic rules that Prettier owns (keep last).
  prettier
);
