import { mountApp } from "./app";
import { getDemoClientConfig, getLastRouteDecision, inderun } from "./demo-client";
import { isVoicesLabEnabled } from "./config";
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

// Opt-in (VITE_INDERUN_VOICES_LAB=1): nothing of the lab is loaded, fetched or registered otherwise.
const labRoot = document.querySelector<HTMLDivElement>("#voices-lab");
if (labRoot && isVoicesLabEnabled()) {
  void import("./voices-lab-main").then(({ startVoicesLab }) => startVoicesLab(labRoot, inderun));
}
