// Carga fija configurable. Uso: make k6-users VUS=500 DURATION=3m
import { setupTracks, listener, baseThresholds } from "./common.js";

const vus = Number(__ENV.VUS || 500);
const duration = __ENV.DURATION || "3m";

if (!Number.isInteger(vus) || vus < 1) {
  throw new Error("VUS debe ser un entero positivo");
}

export const options = {
  vus,
  duration,
  thresholds: baseThresholds,
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export function setup() { return setupTracks(); }
export default function (data) { listener(data); }
