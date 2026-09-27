// Pico: de 0 a 1000 oyentes en 10 segundos. Mide cuánto tarda el HPA en reaccionar.
import { setupTracks, listener } from "./common.js";

export const options = {
  stages: [
    { duration: "30s", target: 20 },
    { duration: "10s", target: 1000 },
    { duration: "2m", target: 1000 },
    { duration: "30s", target: 20 },
    { duration: "1m", target: 20 },
  ],
  thresholds: {
    http_req_failed: ["rate<0.05"],
  },
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export function setup() { return setupTracks(); }
export default function (data) { listener(data); }
