import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";

export const BASE = __ENV.BASE_URL || "http://localhost";
export const segmentTime = new Trend("hls_segment_ms", true);
export const catalogTime = new Trend("catalog_ms", true);
export const servedBy = new Counter("served_by_pods");

const params = { timeout: "30s" };

// Se ejecuta una vez por test: lista las canciones listas para el streaming
export function setupTracks() {
  const res = http.get(`${BASE}/api/tracks?status=ready&limit=500`, params);
  const tracks = res.status === 200 ? res.json() : [];
  if (!tracks.length) console.warn("No hay tracks listas: el test de streaming no tendrá qué reproducir");
  return { ids: tracks.map((t) => t.id) };
}

// Un "oyente": lee catálogo, pide master, variante y 3 segmentos
export function listener(data) {
  const t0 = Date.now();
  const cat = http.get(`${BASE}/api/tracks?limit=50`, params);
  catalogTime.add(Date.now() - t0);
  check(cat, { "catálogo 200": (r) => r.status === 200 });
  if (cat.headers["X-Served-By"]) servedBy.add(1, { pod: cat.headers["X-Served-By"] });

  if (!data.ids.length) { sleep(1); return; }
  const id = data.ids[Math.floor(Math.random() * data.ids.length)];

  const master = http.get(`${BASE}/stream/${id}/master.m3u8`, params);
  if (!check(master, { "master 200": (r) => r.status === 200 })) { sleep(1); return; }
  const variants = master.body.split("\n").filter((l) => l.endsWith("index.m3u8"));
  const variant = variants[Math.floor(Math.random() * variants.length)];

  const index = http.get(`${BASE}/stream/${id}/${variant}`, params);
  if (!check(index, { "variante 200": (r) => r.status === 200 })) { sleep(1); return; }
  const dir = variant.split("/")[0];
  const segs = index.body.split("\n").filter((l) => l.endsWith(".ts")).slice(0, 3);

  for (const s of segs) {
    const t1 = Date.now();
    const seg = http.get(`${BASE}/stream/${id}/${dir}/${s}`, params);
    segmentTime.add(Date.now() - t1);
    check(seg, { "segmento 200": (r) => r.status === 200 });
  }
  sleep(Math.random() * 2 + 0.5);
}

export const baseThresholds = {
  http_req_failed: ["rate<0.01"],
  http_req_duration: ["p(95)<500"],
  hls_segment_ms: ["p(95)<400"],
};
