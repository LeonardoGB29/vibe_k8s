// Carga gradual para ubicar degradación sin el salto brusco del escenario spike.
import { setupTracks, listener, baseThresholds } from "./common.js";

export const options = {
  stages: [
    { duration: "30s", target: 200 },
    { duration: "30s", target: 400 },
    { duration: "30s", target: 600 },
    { duration: "30s", target: 800 },
    { duration: "30s", target: 1000 },
    { duration: "30s", target: 1200 },
    { duration: "1m", target: 1200 },
    { duration: "30s", target: 0 },
  ],
  thresholds: baseThresholds,
  summaryTrendStats: ["avg", "med", "p(95)", "p(99)", "max"],
};

export function setup() { return setupTracks(); }
export default function (data) { listener(data); }
