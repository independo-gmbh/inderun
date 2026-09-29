import { mountApp } from "./app";
import {
  checkProviderCapabilities,
  getDemoClientConfig,
  getLastRouteDecision,
  runPrompt,
  streamPrompt
} from "./demo-client";
import "./styles.css";

const root = document.querySelector<HTMLDivElement>("#app");

if (!root) {
  throw new Error("Missing #app root element.");
}

mountApp(root, {
  config: getDemoClientConfig(),
  runPrompt,
  streamPrompt,
  checkProviderCapabilities,
  getLastRouteDecision
});
