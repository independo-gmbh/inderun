import { mountApp } from "./app";
import { getDemoClientConfig, getLastRouteDecision, inderun } from "./demo-client";
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
