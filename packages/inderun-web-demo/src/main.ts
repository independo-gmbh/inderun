import { mountApp } from "./app";
import { getDemoClientConfig, getLastRouteDecision, inderun } from "./demo-client";
import { mountSpeechPanel } from "./speech-panel";
import "./styles.css";

const root = document.querySelector<HTMLDivElement>("#app");

if (!root) {
  throw new Error("Missing #app root element.");
}

mountApp(root, {
  inderun,
  config: getDemoClientConfig(),
  getLastRouteDecision
});

const speechRoot = document.querySelector<HTMLDivElement>("#speech");
if (speechRoot) mountSpeechPanel(speechRoot, inderun);
