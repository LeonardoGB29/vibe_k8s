#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith("--")) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);

const kind = args.kind;
const output = args.output;
const debuggingPort = Number(args.port || 9222);

if (!kind || !output) {
  throw new Error("Uso: capture_evidence.mjs --kind grafana|k8sweb|url --output archivo.png [--url URL]");
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function newTarget(url) {
  const response = await fetch(
    `http://127.0.0.1:${debuggingPort}/json/new?${encodeURIComponent(url)}`,
    { method: "PUT" },
  );
  if (!response.ok) throw new Error(`No se pudo crear pestaña CDP: ${response.status}`);
  return response.json();
}

async function closeTarget(id) {
  await fetch(`http://127.0.0.1:${debuggingPort}/json/close/${id}`).catch(() => {});
}

async function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result || {});
  });
  const send = (method, params = {}) => {
    const requestId = ++id;
    return new Promise((resolve, reject) => {
      pending.set(requestId, { resolve, reject });
      ws.send(JSON.stringify({ id: requestId, method, params }));
    });
  };
  return { ws, send };
}

async function screenshot(send) {
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1600,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false,
  });
  const result = await send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output, Buffer.from(result.data, "base64"));
}

async function captureGrafana() {
  const target = await newTarget("http://localhost:3000/login");
  const { ws, send } = await connect(target);
  try {
    await send("Page.enable");
    await send("Runtime.enable");
    await sleep(2500);
    const user = JSON.stringify(process.env.GRAFANA_USER || "admin");
    const password = JSON.stringify(process.env.GRAFANA_PASSWORD || "vibe");
    const login = await send("Runtime.evaluate", {
      expression: `fetch('/login', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({user:${user}, password:${password}})}).then(async r => ({status:r.status, body:await r.text()}))`,
      awaitPromise: true,
      returnByValue: true,
    });
    const status = login.result?.value?.status;
    if (status !== 200) throw new Error(`Grafana login falló: ${status}`);
    const dashboard = args.url ||
      "http://localhost:3000/d/85a562078cdf77779eaa1add43ccec1e/kubernetes-compute-resources-namespace-pods?orgId=1&var-datasource=prometheus&var-cluster=&var-namespace=vibe&from=now-10m&to=now";
    await send("Page.navigate", { url: dashboard });
    await sleep(Number(args.wait || 12000));
    await screenshot(send);
  } finally {
    ws.close();
    await closeTarget(target.id);
  }
}

async function captureK8sWeb() {
  const target = await newTarget(args.url || "http://localhost:8085");
  const { ws, send } = await connect(target);
  try {
    await send("Page.enable");
    await send("Runtime.enable");
    await sleep(Number(args.wait || 7000));
    await send("Runtime.evaluate", {
      expression: `document.querySelector('button[data-t="traffic"]')?.click()`,
    });
    await sleep(2500);
    await screenshot(send);
  } finally {
    ws.close();
    await closeTarget(target.id);
  }
}

async function captureUrl() {
  if (!args.url) throw new Error("--url es obligatorio para kind=url");
  const target = await newTarget(args.url);
  const { ws, send } = await connect(target);
  try {
    await send("Page.enable");
    await sleep(Number(args.wait || 2500));
    await screenshot(send);
  } finally {
    ws.close();
    await closeTarget(target.id);
  }
}

if (kind === "grafana") await captureGrafana();
else if (kind === "k8sweb") await captureK8sWeb();
else if (kind === "url") await captureUrl();
else throw new Error(`Tipo de captura desconocido: ${kind}`);

console.log(output);
