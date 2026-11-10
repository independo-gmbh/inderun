---
slug: docs/api/typescript
title: "TypeScript API reference"
description: "Generated reference for the public TypeScript API of the released Capacitor plugin and Web SDK, pinned to the tested versions."
sidebar:
  order: 1
---

The TypeScript reference is generated from the published type declarations (`.d.ts`) of the pinned package versions, so it describes what you install.

<!-- version:tested-set -->
Tested set: IndeRun **0.5.0** (`@independo/inderun-web`, SwiftPM, Maven) and `@independo/capacitor-inderun` **1.3.0-dev.1**, which wraps IndeRun 0.5.0. Examples type-checked against these on 2026-11-11.
<!-- /version -->

- [Capacitor plugin reference](/docs/api/typescript/capacitor): `@independo/capacitor-inderun`, the package most apps start with. Its source of truth is [`src/definitions.ts`](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0-dev.1/src/definitions.ts) at v1.3.0-dev.1
- [Web SDK reference](/docs/api/typescript/web): `@independo/inderun-web`.

## Start here (Capacitor)

The generated index lists every exported type alphabetically. These are the entry points an app uses:

| Name | What it is |
| --- | --- |
| [`createIndeRunCapacitor`](/docs/api/typescript/capacitor/functions/createinderuncapacitor) | Creates the instance your app calls. |
| [`run`](/docs/api/typescript/capacitor/interfaces/inderuncapacitorinstance#run) | Runs one task and resolves with its result, or rejects with an `IndeRunError`. |
| [`stream`](/docs/api/typescript/capacitor/interfaces/inderuncapacitorinstance#stream) | Runs one task and delivers its output as events. |
| [`checkCapabilities`](/docs/api/typescript/capacitor/interfaces/inderuncapacitorinstance#checkcapabilities) | Reports what each provider can do on this device right now. |
| [`ConfigureOptions`](/docs/api/typescript/capacitor/interfaces/configureoptions) | Options for `createIndeRunCapacitor`, such as a cloud provider. |
| [`TaskRequest`](/docs/api/typescript/capacitor/type-aliases/taskrequest) | What you pass to `run` and `stream`, including `constraints.privacy`. |
| [`TaskResult`](/docs/api/typescript/capacitor/type-aliases/taskresult) | What `run` resolves with. |
| [`ExecutionProvenance`](/docs/api/typescript/capacitor/type-aliases/executionprovenance) | Where the task ran (`providerId`, `locality`). |
| [`IndeRunError`](/docs/api/typescript/capacitor/type-aliases/inderunerror) | The normalized error, with `errorClass` and `details`. |

The other entries are contract and host-service types that these refer to.

These two references are generated when the site is built, so the links above work only on the site. Reading this on GitHub? Open them at <https://inderun.dev/docs/api/typescript>.

The Capacitor plugin wraps an older IndeRun release than the Web SDK, so the two references can differ. The versions above are the ones this site was checked against.

## Swift and Kotlin

References for the Swift and Kotlin SDKs are not generated. Use their READMEs instead: [IndeRun for Swift](../../ios/IndeRun/README.md) and [IndeRun for Kotlin](../../android/inderun-kotlin/README.md).
