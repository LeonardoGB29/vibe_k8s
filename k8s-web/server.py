#!/usr/bin/env python3
"""
k8s web: visor local de la arquitectura de un cluster Kubernetes.
Independiente de la app (no se despliega en ningún contenedor).
Solo usa la librería estándar de Python + kubectl del PATH.

    python3 server.py                          # http://localhost:8085, namespace vibe
    python3 server.py --ns otro --port 9000
    python3 server.py --status-script ../vibe/tools/cluster-status.sh   # muestra también la salida del script
"""
import argparse
import json
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
STATE = {"data": None, "error": None, "updated": 0, "script": "", "traffic_prev": {}}
ARGS = None


# ---------- kubectl ----------
def kubectl(*args, timeout=10):
    out = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        msg = out.stderr.strip().splitlines()
        raise RuntimeError(msg[-1] if msg else "kubectl falló")
    return out.stdout


def kjson(*args):
    return json.loads(kubectl(*args, "-o", "json"))


def kjson_safe(*args):
    try:
        return kjson(*args)
    except Exception:  # noqa: BLE001
        return {"items": []}


def cpu_m(v):
    if not v:
        return 0
    v = str(v)
    if v.endswith("n"):
        return int(v[:-1]) / 1e6
    if v.endswith("m"):
        return float(v[:-1])
    return float(v) * 1000


def mem_mi(v):
    if not v:
        return 0
    v = str(v)
    for u, f in {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1048576, "K": 1 / 1048.576, "M": 1 / 1.048576, "G": 953.674}.items():
        if v.endswith(u):
            return float(v[: -len(u)]) * f
    return float(v) / 1048576


def parse_top(text):
    rows = {}
    for line in text.strip().splitlines():
        p = line.split()
        # nodes: NAME CPU CPU% MEM MEM%   |   pods: NAME CPU MEM
        vals = [x for x in p[1:] if not x.endswith("%")]
        if len(vals) >= 2:
            rows[p[0]] = {"cpu_m": cpu_m(vals[0]), "mem_mi": mem_mi(vals[1])}
    return rows


def age(ts):
    if not ts:
        return ""
    s = int((datetime.now(timezone.utc) - datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds())
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h" if s < 86400 else f"{s // 86400}d"


def selector_match(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


# ---------- recolección ----------
def collect(ns):
    with ThreadPoolExecutor(12) as ex:
        f = {
            "nodes": ex.submit(kjson, "get", "nodes"),
            "pods": ex.submit(kjson, "-n", ns, "get", "pods"),
            "deploy": ex.submit(kjson_safe, "-n", ns, "get", "deploy"),
            "sts": ex.submit(kjson_safe, "-n", ns, "get", "statefulset"),
            "svc": ex.submit(kjson_safe, "-n", ns, "get", "svc"),
            "ing": ex.submit(kjson_safe, "-n", ns, "get", "ingress"),
            "hpa": ex.submit(kjson_safe, "-n", ns, "get", "hpa"),
            "so": ex.submit(kjson_safe, "-n", ns, "get", "scaledobject"),
            "pvc": ex.submit(kjson_safe, "-n", ns, "get", "pvc"),
            "cm": ex.submit(kjson_safe, "-n", ns, "get", "configmap"),
            "sec": ex.submit(kjson_safe, "-n", ns, "get", "secret"),
            "events": ex.submit(kjson_safe, "-n", ns, "get", "events"),
            "topn": ex.submit(lambda: kubectl("top", "nodes", "--no-headers")),
            "topp": ex.submit(lambda: kubectl("-n", ns, "top", "pods", "--no-headers")),
        }
    r = {k: v.result() if k not in ("topn", "topp") else safe(v) for k, v in f.items()}
    top_nodes, top_pods = parse_top(r["topn"]), parse_top(r["topp"])

    nodes = []
    for n in r["nodes"]["items"]:
        name = n["metadata"]["name"]
        alloc = n["status"].get("allocatable", {})
        nodes.append({
            "name": name,
            "role": "control-plane" if "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {}) else "worker",
            "ready": any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"].get("conditions", [])),
            "version": n["status"].get("nodeInfo", {}).get("kubeletVersion", ""),
            "cpu_alloc_m": cpu_m(alloc.get("cpu")), "mem_alloc_mi": mem_mi(alloc.get("memory")),
            "cpu_m": top_nodes.get(name, {}).get("cpu_m", 0), "mem_mi": top_nodes.get(name, {}).get("mem_mi", 0),
        })

    pods = []
    for p in r["pods"]["items"]:
        name = p["metadata"]["name"]
        cs = (p["status"].get("containerStatuses") or [{}])[0]
        c0 = p["spec"]["containers"][0]
        res = c0.get("resources", {})
        st = cs.get("state", {})
        state = "Running" if "running" in st else st.get("waiting", {}).get("reason") or st.get("terminated", {}).get("reason") or p["status"].get("phase", "?")
        if p["metadata"].get("deletionTimestamp"):
            state = "Terminating"
        owner = (p["metadata"].get("ownerReferences") or [{}])[0]
        claims = [v["persistentVolumeClaim"]["claimName"] for v in p["spec"].get("volumes", []) if "persistentVolumeClaim" in v]
        pods.append({
            "name": name, "labels": p["metadata"].get("labels", {}), "app": p["metadata"].get("labels", {}).get("app", "?"),
            "node": p["spec"].get("nodeName", ""), "state": state, "ready": bool(cs.get("ready")),
            "restarts": cs.get("restartCount", 0), "ip": p["status"].get("podIP", ""), "age": age(p["metadata"].get("creationTimestamp")),
            "image": c0.get("image", ""), "owner_kind": owner.get("kind", ""), "owner": owner.get("name", ""), "pvcs": claims,
            "req_cpu_m": cpu_m(res.get("requests", {}).get("cpu")), "req_mem_mi": mem_mi(res.get("requests", {}).get("memory")),
            "lim_cpu_m": cpu_m(res.get("limits", {}).get("cpu")), "lim_mem_mi": mem_mi(res.get("limits", {}).get("memory")),
            "cpu_m": top_pods.get(name, {}).get("cpu_m", 0), "mem_mi": top_pods.get(name, {}).get("mem_mi", 0),
        })

    workloads = []
    for kind, key in (("Deployment", "deploy"), ("StatefulSet", "sts")):
        for w in r[key]["items"]:
            tl = w["spec"]["template"]["metadata"].get("labels", {})
            members = [p["name"] for p in pods if selector_match(w["spec"]["selector"].get("matchLabels", {}), p["labels"])]
            workloads.append({
                "kind": kind, "name": w["metadata"]["name"], "labels": tl,
                "desired": w["spec"].get("replicas", 0), "ready": w["status"].get("readyReplicas", 0) or 0,
                "image": w["spec"]["template"]["spec"]["containers"][0].get("image", ""),
                "pods": members,
                "pvc_templates": [t["metadata"]["name"] for t in w["spec"].get("volumeClaimTemplates", [])] if kind == "StatefulSet" else [],
                "strategy": (w["spec"].get("strategy") or w["spec"].get("updateStrategy") or {}).get("type", ""),
            })

    services = []
    for s in r["svc"]["items"]:
        sel = s["spec"].get("selector", {})
        targets = [w["name"] for w in workloads if selector_match(sel, w["labels"])]
        services.append({
            "name": s["metadata"]["name"], "type": s["spec"].get("type", "ClusterIP"),
            "cluster_ip": s["spec"].get("clusterIP", ""), "ports": [f"{p['port']}{'/' + p['name'] if p.get('name') else ''}" for p in s["spec"].get("ports", [])],
            "targets": targets, "selector": sel,
        })

    ingresses = []
    for i in r["ing"]["items"]:
        rules = []
        for rule in i["spec"].get("rules", []):
            for path in rule.get("http", {}).get("paths", []):
                b = path["backend"].get("service", {})
                rules.append({"host": rule.get("host", "*"), "path": path.get("path", "/"), "service": b.get("name", ""), "port": b.get("port", {}).get("number", "")})
        ingresses.append({"name": i["metadata"]["name"], "class": i["spec"].get("ingressClassName", ""), "rules": rules})

    hpas = []
    for h in r["hpa"]["items"]:
        metric = ""
        for m in h["status"].get("currentMetrics") or []:
            if m.get("type") == "Resource":
                metric = f"CPU {m['resource']['current'].get('averageUtilization', '?')}%"
            elif m.get("type") == "External":
                metric = f"{m['external'].get('metric', {}).get('name', 'ext')}={m['external']['current'].get('averageValue') or m['external']['current'].get('value', '')}"
        target_desc = ""
        for m in h["spec"].get("metrics", []):
            if m.get("type") == "Resource":
                target_desc = f"CPU objetivo {m['resource']['target'].get('averageUtilization', '?')}%"
        hpas.append({"name": h["metadata"]["name"], "target": h["spec"]["scaleTargetRef"]["name"], "min": h["spec"].get("minReplicas", 1),
                     "max": h["spec"]["maxReplicas"], "current": h["status"].get("currentReplicas", 0), "desired": h["status"].get("desiredReplicas", 0),
                     "metric": metric, "target_desc": target_desc})

    scaled = [{"name": s["metadata"]["name"], "target": s["spec"]["scaleTargetRef"]["name"], "min": s["spec"].get("minReplicaCount", 0),
               "max": s["spec"].get("maxReplicaCount", 0), "triggers": [t["type"] for t in s["spec"].get("triggers", [])],
               "active": any(c["type"] == "Active" and c["status"] == "True" for c in s["status"].get("conditions", []))}
              for s in r["so"]["items"]]

    pvcs = [{"name": p["metadata"]["name"], "phase": p["status"].get("phase", ""), "size": p["status"].get("capacity", {}).get("storage", p["spec"]["resources"]["requests"].get("storage", "")),
             "modes": p["spec"].get("accessModes", []), "class": p["spec"].get("storageClassName", "")} for p in r["pvc"]["items"]]

    configs = [{"kind": "ConfigMap", "name": c["metadata"]["name"], "keys": len(c.get("data", {}) or {})} for c in r["cm"]["items"] if not c["metadata"]["name"].startswith("kube-")]
    configs += [{"kind": "Secret", "name": s["metadata"]["name"], "keys": len(s.get("data", {}) or {})} for s in r["sec"]["items"] if s.get("type") == "Opaque"]

    events = sorted(r["events"]["items"], key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "", reverse=True)[:15]
    events = [{"type": e.get("type", ""), "reason": e.get("reason", ""), "object": f"{e['involvedObject'].get('kind', '')}/{e['involvedObject'].get('name', '')}",
               "message": (e.get("message") or "")[:160], "age": age(e.get("lastTimestamp") or e.get("eventTime"))} for e in events]

    try:
        traffic = collect_traffic(ns, pods)
    except Exception:  # noqa: BLE001
        traffic = {"pods": [], "rps": 0, "seg_ps": 0, "mbps": 0, "total": 0}
    ctx = safe_str(lambda: kubectl("config", "current-context").strip())
    return {"ns": ns, "context": ctx, "time": datetime.now().strftime("%H:%M:%S"), "metrics_ok": bool(top_pods),
            "nodes": nodes, "pods": pods, "workloads": workloads, "services": services, "ingresses": ingresses,
            "hpas": hpas, "scaled": scaled, "pvcs": pvcs, "configs": configs, "events": events, "traffic": traffic}


# ---------- tráfico: /metrics de cada pod api vía el proxy del API server ----------
def pod_metrics(ns, pod, port=8000):
    txt = kubectl("get", "--raw", f"/api/v1/namespaces/{ns}/pods/{pod}:{port}/proxy/metrics", timeout=5)
    req = seg = byts = 0.0
    by_handler = {}
    for line in txt.splitlines():
        if line.startswith("http_requests_total{"):
            labels, val = line.rsplit(" ", 1)
            if 'handler="/metrics"' in labels:
                continue
            req += float(val)
            h = labels.split('handler="')[1].split('"')[0] if 'handler="' in labels else "?"
            by_handler[h] = by_handler.get(h, 0.0) + float(val)
        elif line.startswith("vibe_stream_segments_total "):
            seg = float(line.split()[1])
        elif line.startswith("vibe_stream_bytes_total "):
            byts = float(line.split()[1])
    return {"req": req, "seg": seg, "bytes": byts, "by_handler": by_handler}


def collect_traffic(ns, pods):
    now = time.time()
    prev = STATE["traffic_prev"]
    api_pods = [p for p in pods if p["app"] == "api" and p["ready"]]
    with ThreadPoolExecutor(8) as ex:
        futs = {p["name"]: ex.submit(pod_metrics, ns, p["name"]) for p in api_pods}
    rows, cur = [], {}
    for name, fut in futs.items():
        try:
            m = fut.result()
        except Exception:  # noqa: BLE001
            continue
        cur[name] = (now, m)
        rps = seg_ps = mbps = 0.0
        if name in prev:
            t0, m0 = prev[name]
            dt = max(0.5, now - t0)
            rps = max(0.0, (m["req"] - m0["req"]) / dt)
            seg_ps = max(0.0, (m["seg"] - m0["seg"]) / dt)
            mbps = max(0.0, (m["bytes"] - m0["bytes"]) / dt * 8 / 1e6)
        rows.append({"pod": name, "node": next((p["node"] for p in api_pods if p["name"] == name), ""),
                     "rps": round(rps, 1), "seg_ps": round(seg_ps, 1), "mbps": round(mbps, 2), "total": int(m["req"])})
    STATE["traffic_prev"] = cur
    rows.sort(key=lambda r: r["pod"])
    return {"pods": rows, "rps": round(sum(r["rps"] for r in rows), 1), "seg_ps": round(sum(r["seg_ps"] for r in rows), 1),
            "mbps": round(sum(r["mbps"] for r in rows), 2), "total": sum(r["total"] for r in rows)}


def safe(fut):
    try:
        return fut.result()
    except Exception:  # noqa: BLE001
        return ""


def safe_str(fn):
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return ""


def run_status_script():
    if not ARGS.status_script:
        return ""
    path = Path(ARGS.status_script)
    if not path.exists():
        return f"(no se encontró {path})"
    try:
        out = subprocess.run(["bash", str(path)], capture_output=True, text=True, timeout=25, cwd=path.parent.parent)
        return out.stdout + out.stderr
    except Exception as exc:  # noqa: BLE001
        return f"(error ejecutando el script: {exc})"


def refresher():
    n = 0
    while True:
        try:
            STATE["data"] = collect(ARGS.ns)
            STATE["error"] = None
        except Exception as exc:  # noqa: BLE001
            STATE["error"] = str(exc)
        if n % 3 == 0:
            STATE["script"] = run_status_script()
        STATE["updated"] = time.time()
        n += 1
        time.sleep(ARGS.interval)


# ---------- http ----------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/cluster"):
            self.send(200, json.dumps({"data": STATE["data"], "error": STATE["error"], "script": STATE["script"]}).encode(), "application/json")
        elif self.path == "/" or self.path.startswith("/index"):
            self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        else:
            self.send(404, b"not found", "text/plain")


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8085)
    ap.add_argument("--ns", default="vibe")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--status-script", default=str(HERE.parent / "vibe" / "tools" / "cluster-status.sh"),
                    help="script cuya salida se muestra en la pestaña Terminal ('' para desactivar)")
    ARGS = ap.parse_args()
    threading.Thread(target=refresher, daemon=True).start()
    print(f"k8s web -> http://localhost:{ARGS.port}   (namespace {ARGS.ns}, Ctrl+C para salir)")
    try:
        ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler).serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
