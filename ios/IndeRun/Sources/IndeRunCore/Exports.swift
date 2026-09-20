//
//  Exports.swift
//  IndeRunCore
//
//  Re-exports IndeRunContracts to consumers of this module.
//
//  This is the SwiftPM analogue of Gradle's `api(...)` vs `implementation(...)`
//  distinction, which the Android SDK relies on for the same reason (see
//  https://github.com/independo-gmbh/inderun/issues/189). A Swift module does not
//  re-export what it imports, so without this line a consumer holding only
//  `import IndeRunCore` cannot name `TaskRequest`, `TaskResult`, `StreamEvent` or
//  `ModelPackage` -- the exact types this module's own public API takes and
//  returns (`ProviderAdapter`, `StreamRun`, `HostServices`). Making callers add a
//  second import for types they never chose to depend on separately is the same
//  packaging mistake as leaving a public dependency at `implementation` scope.
//

@_exported import IndeRunContracts
