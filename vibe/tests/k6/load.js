// Carga normal: sube gradualmente a 300 oyentes, se mantiene y baja.
import { setupTracks, listener, baseThresholds } from "./common.js";

export const options = {
  stages: [
    { duration: "1m", target: 100 },
    { duration: "2m", target: 300 },
    { duration: "3m", target: 300 },
    { duration: "1m", target: 0 },
  ],
  thresholds: baseThresholds,
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export function setup() { return setupTracks(); }
export default function (data) { listener(data); }
