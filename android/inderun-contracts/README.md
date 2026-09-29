# IndeRun Contracts (Android)

Generated Kotlin contract models for the schema-backed IndeRun payloads used by the Android SDK.

The source of truth is `contracts/schemas/*.schema.json`. Regenerate this module with:

```sh
pnpm generate
```

## Enum wire values

Every generated enum is `enum class X(val rawValue: String)` with a `fromRawValue` companion. Use
`rawValue` for the schema spelling and never `name`, which is a Kotlin identifier and differs for
most enums:

```kotlin
Phase.ProviderSelected.rawValue      // "provider_selected"
Phase.ProviderSelected.name          // "ProviderSelected" -- not the wire value
Phase.fromRawValue("provider_selected") // Phase.ProviderSelected, or null if unknown
```

`fromRawValue` returns `null` rather than throwing, matching Swift's `X(rawValue:)`: a value from a
newer peer is a `null` to fold into a fallback, not a crash.
