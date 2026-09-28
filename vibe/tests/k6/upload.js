// Subidas concurrentes: llena la cola de transcodificación y dispara KEDA.
// Ejecutar desde la raíz del repo (lee data/audio/*.mp3).
import http from "k6/http";
import { check, sleep } from "k6";
import { BASE } from "./common.js";

const FILES = [
  "../../data/audio/001 - DJ Replica - Lunar Horizon.mp3",
].map((p) => open(p, "b"));

export const options = {
  scenarios: {
    uploads: {
      executor: "shared-iterations",
      vus: 20,
      iterations: Number(__ENV.UPLOADS || 200),
      maxDuration: "10m",
    },
  },
  thresholds: { http_req_failed: ["rate<0.02"] },
};

export default function () {
  const i = __ITER;
  const body = {
    file: http.file(FILES[i % FILES.length], `k6-${i}.mp3`, "audio/mpeg"),
    title: `k6 upload ${i}`,
    artist: "k6",
    album: "Escalabilidad",
  };
  const res = http.post(`${BASE}/api/upload`, body, { timeout: "120s" });
  check(res, { "upload 201": (r) => r.status === 201 });
  sleep(0.2);
}
