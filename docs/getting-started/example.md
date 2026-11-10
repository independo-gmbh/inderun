---
slug: docs/getting-started/example
title: "Local-only starter app"
description: "Run a credential-free Capacitor starter that shows what the device can run, executes a local-only task, and refuses cleanly on unsupported devices."
sidebar:
  order: 2
---

## What you'll build

A one-screen Capacitor app with no credentials and no server: a text box, a **Run on device** button, a list of what the device can run, and an output area. On an eligible device it shows the result and where it ran. On an unsupported device it shows the refusal and the providers that were rejected. Both outcomes are correct.

> [!NOTE]
> The planned starter repository does not exist yet, so this page has you build the same screen yourself. Nothing here claims a result from any particular device; use [your own run](#record-your-run) for that.

## Prerequisites

- Node 24 or newer, and the host requirements from the [Capacitor quickstart](capacitor.md#before-you-start).
- A physical iOS or Android device. Xcode 26 for iOS, Android Studio for Android.

## Create the app

Create a new Capacitor app and add the native platforms, following the [Capacitor getting started guide](https://capacitorjs.com/docs/getting-started). The starter works with whichever package manager your app uses. This page shows npm commands; use the equivalent command of your own package manager (for example `pnpm create @capacitor/app@latest`, `pnpm add` and `pnpm build`):

```sh
npm init @capacitor/app@latest
npx cap add ios
npx cap add android
```

Run the commands inside the new project folder (after `npm init` has created it and you have run `npm install` there if the prompts did not). Before you sync iOS, set the deployment target to 16.0 and apply the Android settings described in the quickstart.

## Add the plugin

<!-- version:capacitor-install -->
```sh
npm install @independo/capacitor-inderun@1.2.0 @capacitor/core@8
```
<!-- /version -->

Set the iOS deployment target and the Android values from the quickstart, then sync:

```sh
npx cap sync
```

## Add the screen

Put this markup in the app's `index.html` body:

```html
<main>
  <h1>IndeRun local-only starter</h1>
  <label for="prompt">Text to rewrite</label>
  <textarea id="prompt" rows="4">Rewrite in plain language: Your appointment has been rescheduled.</textarea>
  <button id="run" type="button">Run on device</button>
  <h2>What this device can run</h2>
  <ul id="capabilities"></ul>
  <h2>Result</h2>
  <pre id="output" aria-live="polite"></pre>
</main>
```

Save this as a TypeScript module and load it from your app's entry file (for example `import "./starter";`):

<!-- snippet:capacitor-starter -->
```ts
import { createIndeRunCapacitor, type IndeRunError } from "@independo/capacitor-inderun";

// iOS and Android register the platform's on-device model; no cloud provider is configured.
const ai = createIndeRunCapacitor();

type RejectedProvider = { providerId: string; reasons: { code: string }[] };

const byId = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const prompt = byId<HTMLTextAreaElement>("prompt");
const button = byId<HTMLButtonElement>("run");
const capabilityList = byId<HTMLUListElement>("capabilities");
const output = byId<HTMLPreElement>("output");

function addItem(list: HTMLElement, text: string) {
  const item = document.createElement("li");
  item.textContent = text;
  list.append(item);
}

async function showCapabilities() {
  capabilityList.replaceChildren();
  for (const provider of await ai.checkCapabilities()) {
    const { available, reason } = provider.capabilities;
    addItem(
      capabilityList,
      `${provider.providerId} (${provider.descriptor.type}): ` +
        (available ? "available" : `unavailable: ${reason ?? "no reason reported"}`)
    );
  }
}

async function runLocalOnly() {
  button.disabled = true;
  output.textContent = "Running…";
  try {
    const result = await ai.run({
      schemaVersion: "1.0",
      task: { kind: "text_to_text" },
      prompt: prompt.value,
      constraints: { privacy: "local_required" }
    });
    output.textContent = [
      result.output.text,
      "",
      `provider: ${result.provenance?.providerId}`,
      `locality: ${result.provenance?.locality}`
    ].join("\n");
  } catch (error) {
    const refusal = error as IndeRunError;
    const rejected = (refusal.details?.rejectedProviders ?? []) as RejectedProvider[];
    output.textContent = [
      `Refused: ${refusal.message}`,
      ...rejected.map(
        (entry) => `- ${entry.providerId}: ${entry.reasons.map((r) => r.code).join(", ")}`
      )
    ].join("\n");
  } finally {
    button.disabled = false;
  }
}

button.addEventListener("click", () => void runLocalOnly());
void showCapabilities();
```
<!-- /snippet -->

The request uses `local_required` and no cloud provider is configured, so nothing can leave the device.

## Build and run

Build your web assets with the project's build script (`npm run build`, or `pnpm build` with pnpm), then sync and run on a connected device. [`npx cap run`](https://capacitorjs.com/docs/cli/commands/run) syncs first, builds and deploys; `--list` shows the available targets:

```sh
npm run build
npx cap run ios --list
npx cap run ios --target <device-id>
npx cap run android --list
npx cap run android --target <device-id>
```

## Expected result

**On an eligible device**, the capability list shows the on-device provider as available. After you press **Run on device**, the output area shows the rewritten text, the provider id and `locality: on_device`.

**On an unsupported device**, the capability list shows the provider as unavailable with the platform's reason, and pressing the button shows `Refused: No eligible local provider found for task 'text_to_text'.` followed by each rejected provider and its reason codes. That refusal is the correct outcome: the device cannot run the task under `local_required`, and nothing ran. See [Read the outcome](capacitor.md#read-the-outcome).

## Record your run

If you want a record of what you saw on your device (model, OS version, available or refused, reason codes), see the [device record template](../verification/website-launch-template.md). Please record only what you observed.

## Diagnostic app

For advanced bridge testing, the plugin repository ships a larger [diagnostic example app](https://github.com/independo-gmbh/capacitor-inderun/tree/v1.2.0/example-app) (pinned to v1.2.0).
