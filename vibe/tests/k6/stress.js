// Estrés: escalones hasta 1500 oyentes para encontrar el punto de quiebre.
import { setupTracks, listener } from "./common.js";

export const options = {
  stages: [
    { duration: "1m", target: 250 },
    { duration: "1m", target: 500 },
    { duration: "1m", target: 750 },
    { duration: "1m", target: 1000 },
    { duration: "1m", target: 1500 },
    { duration: "2m", target: 1500 },
    { duration: "1m", target: 0 },
  ],
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<1500"],
  },
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export function setup() { return setupTracks(); }
export default function (data) { listener(data); }
