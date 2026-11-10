---
slug: docs
title: "Introduction"
description: "IndeRun runs AI text tasks on the device's own model where available and applies your fallback rule everywhere else. Check whether it fits your app."
---

IndeRun lets an app ask for an AI text task (summarise, simplify, rewrite) and decides where it may run on _this_ device. On iOS that can be Apple Foundation Models, on Android Gemini Nano through ML Kit GenAI, in a browser a browser-managed model. Whether any of them is available depends on the device, its settings and the model's state, so IndeRun checks first.

Each request carries a rule. `local_required` means the task runs on the device or is refused before anything executes. `local_preferred` tries the device first and allows a cloud provider only if your app has configured one. Either way, the result or the refusal says what happened and why.

**Is it the right tool?** If you target a single platform and are happy to handle unavailability yourself, a platform API or a single-platform plugin is simpler. IndeRun helps when the same feature must behave predictably on iOS, Android and the web, and when "never send this to the cloud" must be enforceable rather than a convention.

**Start:** [Capacitor quickstart](getting-started/capacitor.md). For Web, Swift and Kotlin, check [Compatibility and requirements](platforms/compatibility.md), then follow the package guide:

- Web / TypeScript: [`@independo/inderun-web` README](../packages/inderun-web/README.md)
- Swift: [IndeRun for Swift README](../ios/IndeRun/README.md)
- Kotlin: [`inderun-kotlin` README](../android/inderun-kotlin/README.md)

IndeRun doesn't send usage data to Independo. The `telemetry` you'll see in the API is a local hook for your app.

## Where to go next

- [Local-only starter app](getting-started/example.md): build a credential-free one-screen app that checks the device and refuses cleanly.
- [When on-device AI is unavailable](concepts/routing-and-privacy.md): `local_required`, `local_preferred` and opt-in cloud routes.
- [How IndeRun is structured](concepts/architecture.md): platform SDKs, engine and router, host services, provider adapters.
- [Troubleshooting builds and models](guides/troubleshooting.md): build failures and the difference between an unavailable model and a refused route.
