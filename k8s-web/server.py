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
import codecs
import copy
import json
import os
import re
import signal
import subprocess
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
VIBE_DIR = HERE.parent / "vibe"
STATE = {"data": None, "error": None, "updated": 0, "script": "", "traffic_prev": {}}
ARGS = None

ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
DURATION = re.compile(r"^[1-9][0-9]*(?:ms|s|m|h)$")
SAFE_VERSION = re.compile(r"^[A-Za-z0-9._-]+$")

TEST_CATALOG = [
    {
        "id": "load", "group": "Rendimiento", "title": "Carga sostenida",
        "description": "Sube gradualmente hasta 300 oyentes y mantiene la carga.",
        "duration": "≈ 7 min", "destructive": False,
        "params": [{"name": "repetitions", "label": "Repeticiones", "type": "number", "default": 1, "min": 1, "max": 3}],
    },
    {
        "id": "stress", "group": "Rendimiento", "title": "Estrés progresivo",
        "description": "Escalones de 250 a 1500 oyentes para localizar el punto de quiebre.",
        "duration": "≈ 8 min", "destructive": False,
        "params": [{"name": "repetitions", "label": "Repeticiones", "type": "number", "default": 1, "min": 1, "max": 3}],
    },
    {
        "id": "spike", "group": "Rendimiento", "title": "Pico repentino",
        "description": "Salto rápido de 20 a 1000 oyentes para medir la reacción del HPA.",
        "duration": "≈ 4 min", "destructive": False,
        "params": [{"name": "repetitions", "label": "Repeticiones", "type": "number", "default": 1, "min": 1, "max": 3}],
    },
    {
        "id": "users", "group": "Rendimiento", "title": "Usuarios fijos",
        "description": "Ejecuta una cantidad exacta de oyentes durante una ventana definida.",
        "duration": "Configurable", "destructive": False,
        "params": [
            {"name": "vus", "label": "Usuarios virtuales", "type": "number", "default": 500, "min": 1, "max": 3000},
            {"name": "duration", "label": "Duración", "type": "duration", "default": "3m", "placeholder": "3m"},
            {"name": "repetitions", "label": "Repeticiones", "type": "number", "default": 1, "min": 1, "max": 3},
        ],
    },
    {
        "id": "worker", "group": "Escalabilidad", "title": "Worker y KEDA",
        "description": "Sube audios, llena la cola Redis y registra el escalado del worker.",
        "duration": "Hasta vaciar la cola", "destructive": False,
        "params": [{"name": "uploads", "label": "Audios a subir", "type": "number", "default": 200, "min": 1, "max": 1000}],
    },
    {
        "id": "pod_failure", "group": "Resiliencia", "title": "Fallo de pod",
        "description": "Elimina réplicas de una API y mide cuánto tarda Kubernetes en recuperarlas.",
        "duration": "Según repeticiones", "destructive": True,
        "confirm": "Se eliminarán pods de la API seleccionada. Kubernetes los recreará automáticamente.",
        "params": [
            {"name": "app", "label": "Servicio", "type": "select", "default": "catalog-api", "options": ["catalog-api", "stream-api", "upload-api"]},
            {"name": "interval", "label": "Intervalo (s)", "type": "number", "default": 15, "min": 1, "max": 120},
            {"name": "times", "label": "Cantidad de fallos", "type": "number", "default": 6, "min": 1, "max": 20},
            {"name": "with_load", "label": "Generar carga simultánea", "type": "boolean", "default": True},
        ],
    },
    {
        "id": "node_failure", "group": "Resiliencia", "title": "Caída de nodo",
        "description": "Apaga temporalmente un worker de kind y observa la reprogramación de pods.",
        "duration": "≈ 3 min", "destructive": True,
        "confirm": "Se apagará temporalmente un nodo Docker del cluster local. Si aloja PostgreSQL, MinIO o Redis, ese servicio también quedará interrumpido hasta restaurarlo.",
        "params": [
            {"name": "node", "label": "Nodo", "type": "select", "default": "vibe-worker2", "options": ["vibe-worker", "vibe-worker2", "vibe-worker3"]},
            {"name": "down", "label": "Segundos apagado", "type": "number", "default": 180, "min": 30, "max": 600},
            {"name": "with_load", "label": "Generar carga simultánea", "type": "boolean", "default": False},
        ],
    },
    {
        "id": "db_failure", "group": "Resiliencia", "title": "Reinicio de PostgreSQL",
        "description": "Recrea el pod de base de datos y comprueba PVC y cantidad de pistas.",
        "duration": "≈ 1–3 min", "destructive": True,
        "confirm": "PostgreSQL dejará de estar disponible brevemente mientras Kubernetes recrea el pod.",
        "params": [{"name": "with_load", "label": "Generar carga simultánea", "type": "boolean", "default": False}],
    },
    {
        "id": "rolling", "group": "Resiliencia", "title": "Rolling update",
        "description": "Despliega otra etiqueta del frontend, mide errores y restaura la imagen original.",
        "duration": "≈ 2–7 min", "destructive": True,
        "confirm": "Se realizará un rolling update real del frontend y luego se restaurará la imagen actual.",
        "params": [
            {"name": "version", "label": "Versión temporal", "type": "text", "default": "v2", "placeholder": "v2"},
            {"name": "with_load", "label": "Generar carga simultánea", "type": "boolean", "default": True},
        ],
    },
    {
        "id": "oom", "group": "Resiliencia", "title": "Límite de memoria",
        "description": "Reduce la memoria del worker, encola un audio y verifica OOMKilled.",
        "duration": "Hasta 4 min", "destructive": True,
        "confirm": "El worker entrará en OOMKilled. Después usa la acción Restaurar memoria.",
        "params": [],
    },
    {
        "id": "oom_restore", "group": "Recuperación", "title": "Restaurar memoria",
        "description": "Devuelve el límite del worker a 512 MiB y espera su recuperación.",
        "duration": "≈ 1 min", "destructive": False, "params": [],
    },
]
TEST_BY_ID = {item["id"]: item for item in TEST_CATALOG}
STATELESS_APPS = {"frontend", "catalog-api", "upload-api", "stream-api", "worker"}


def test_catalog_view():
    """Return the catalog with node choices annotated from the latest cluster snapshot."""
    catalog = copy.deepcopy(TEST_CATALOG)
    data = STATE.get("data") or {}
    workers = [node["name"] for node in data.get("nodes", []) if node.get("role") == "worker" and node.get("ready")]
    pods = [pod for pod in data.get("pods", []) if pod.get("state") != "Terminating"]
    if not workers:
        return catalog

    stateless = {
        node: [pod for pod in pods if pod.get("node") == node and pod.get("app") in STATELESS_APPS]
        for node in workers
    }
    stateful = {
        node: [pod for pod in pods if pod.get("node") == node and pod.get("pvcs")]
        for node in workers
    }
    candidates = [node for node in workers if stateless[node]]
    penalty = {"postgres": 100, "minio": 50, "redis": 20}

    def risk(node):
        return sum(penalty.get(pod.get("app"), 10) for pod in stateful[node])

    recommended = min(candidates, key=lambda node: (risk(node), -len(stateless[node]), node)) if candidates else workers[0]
    ordered = sorted(workers, key=lambda node: (node not in candidates, node != recommended, risk(node), node))
    labels = {}
    for node in ordered:
        services = ", ".join(sorted({pod.get("app", "?") for pod in stateful[node]})) or "sin PVC"
        labels[node] = f"{node} — {len(stateless[node])} pods stateless; {services}"

    node_test = next(test for test in catalog if test["id"] == "node_failure")
    node_param = next(param for param in node_test["params"] if param["name"] == "node")
    node_param.update({
        "default": recommended,
        "options": ordered,
        "option_labels": labels,
        "help": "La recomendación se recalcula según la ubicación actual de los pods.",
    })
    return catalog


def normalize_params(test_id, supplied):
    supplied = supplied if isinstance(supplied, dict) else {}
    spec = TEST_BY_ID[test_id]
    allowed = {p["name"] for p in spec["params"]}
    unknown = set(supplied) - allowed
    if unknown:
        raise ValueError(f"Parámetros desconocidos: {', '.join(sorted(unknown))}")
    result = {}
    for field in spec["params"]:
        name, kind = field["name"], field["type"]
        value = supplied.get(name, field.get("default"))
        if kind == "number":
            if isinstance(value, bool):
                raise ValueError(f"{field['label']} debe ser un número")
            try:
                value = int(value)
            except (TypeError, ValueError) as exc:
                raise ValueError(f"{field['label']} debe ser un entero") from exc
            if value < field["min"] or value > field["max"]:
                raise ValueError(f"{field['label']} debe estar entre {field['min']} y {field['max']}")
        elif kind == "boolean":
            if not isinstance(value, bool):
                raise ValueError(f"{field['label']} debe ser verdadero o falso")
        elif kind == "select":
            if value not in field["options"]:
                raise ValueError(f"Valor inválido para {field['label']}")
        elif kind == "duration":
            value = str(value)
            if not DURATION.fullmatch(value):
                raise ValueError(f"{field['label']} debe tener formato como 30s, 3m o 1h")
        elif kind == "text":
            value = str(value).strip()
            if not SAFE_VERSION.fullmatch(value):
                raise ValueError(f"{field['label']} contiene caracteres inválidos")
        result[name] = value
    return result


def make_command(test_id, params):
    commands = {
        "load": ["make", "--silent", "k6-load"],
        "stress": ["make", "--silent", "k6-stress"],
        "spike": ["make", "--silent", "k6-spike"],
        "users": ["make", "--silent", "k6-users", f"VUS={params.get('vus')}", f"DURATION={params.get('duration')}"],
        "worker": ["make", "--silent", "worker-scale", f"UPLOADS={params.get('uploads')}"],
        "pod_failure": ["make", "--silent", "chaos-pod", f"INTERVAL={params.get('interval')}", f"TIMES={params.get('times')}", f"APP={params.get('app')}"],
        "node_failure": ["make", "--silent", "chaos-node", f"NODE={params.get('node')}", f"DOWN={params.get('down')}"],
        "db_failure": ["make", "--silent", "chaos-db"],
        "rolling": ["make", "--silent", "chaos-rolling", f"VERSION={params.get('version')}"],
        "oom": ["make", "--silent", "chaos-oom"],
        "oom_restore": ["make", "--silent", "chaos-oom-restore"],
    }
    return commands[test_id]


class TestManager:
    def __init__(self):
        self.lock = threading.RLock()
        self.current = None
        self.history = deque(maxlen=10)
        self.logs = deque(maxlen=800)
        self.log_seq = 0
        self.processes = {}
        self.cancel_event = threading.Event()

    def _log(self, source, message):
        message = ANSI.sub("", str(message)).replace("\x00", "").strip()
        if not message:
            return
        with self.lock:
            self.log_seq += 1
            self.logs.append({"seq": self.log_seq, "time": datetime.now().strftime("%H:%M:%S"), "source": source, "text": message})

    def status(self):
        with self.lock:
            current = dict(self.current) if self.current else None
            if current and current.get("started_epoch"):
                end = current.get("ended_epoch") or time.time()
                current["elapsed_seconds"] = round(end - current["started_epoch"], 1)
            if current:
                current.pop("started_epoch", None)
                current.pop("ended_epoch", None)
            return {"current": current, "logs": list(self.logs), "history": list(self.history)}

    def start(self, test_id, supplied):
        if test_id not in TEST_BY_ID:
            raise ValueError("Prueba desconocida")
        params = normalize_params(test_id, supplied)
        with self.lock:
            if self.current and self.current["status"] in {"starting", "running", "stopping"}:
                raise RuntimeError("Ya hay una prueba en ejecución")
            spec = TEST_BY_ID[test_id]
            self.logs.clear()
            self.log_seq = 0
            self.processes.clear()
            self.cancel_event = threading.Event()
            self.current = {
                "id": f"{int(time.time())}-{test_id}", "test_id": test_id,
                "title": spec["title"], "group": spec["group"], "params": params,
                "status": "starting", "phase": "Preparando", "outcome": None,
                "started_at": datetime.now().isoformat(timespec="seconds"),
                "started_epoch": time.time(), "ended_at": None, "ended_epoch": None,
                "exit_code": None, "error": None, "artifacts": [],
            }
        threading.Thread(target=self._run, args=(test_id, params), daemon=True).start()
        return self.status()["current"]

    def _set(self, **changes):
        with self.lock:
            if self.current:
                self.current.update(changes)

    def _spawn(self, command, label):
        if not VIBE_DIR.is_dir():
            raise RuntimeError(f"No existe {VIBE_DIR}")
        kwargs = {
            "cwd": VIBE_DIR, "stdout": subprocess.PIPE, "stderr": subprocess.STDOUT,
            "stdin": subprocess.DEVNULL, "bufsize": 0,
        }
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            kwargs["start_new_session"] = True
        proc = subprocess.Popen(command, **kwargs)
        with self.lock:
            self.processes[proc.pid] = proc
        self._log("sistema", f"Iniciando: {label}")
        pump = threading.Thread(target=self._pump, args=(proc, label), daemon=True)
        pump.start()
        return proc, pump

    def _pump(self, proc, label):
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        pending = ""
        while True:
            chunk = proc.stdout.read(512) if proc.stdout else b""
            if not chunk:
                break
            pending += decoder.decode(chunk)
            parts = re.split(r"[\r\n]+", pending)
            pending = parts.pop()
            for line in parts:
                self._log(label, line)
        pending += decoder.decode(b"", final=True)
        self._log(label, pending)

    def _wait(self, proc, pump):
        code = proc.wait()
        pump.join(timeout=2)
        if proc.stdout:
            proc.stdout.close()
        with self.lock:
            self.processes.pop(proc.pid, None)
        return code

    def _sleep_cancelable(self, seconds):
        return self.cancel_event.wait(seconds)

    def _run_once(self, test_id, params, repetition, total):
        self._set(phase=f"Ejecución {repetition}/{total}")
        if total > 1:
            self._log("sistema", f"Repetición {repetition} de {total}")
        companion = None
        if params.get("with_load"):
            companion = self._spawn(["make", "--silent", "k6-load"], "carga")
            self._set(phase="Estabilizando carga simultánea")
            if self._sleep_cancelable(10):
                return [self._wait(*companion)]
        main = self._spawn(make_command(test_id, params), TEST_BY_ID[test_id]["title"])
        self._set(status="running", phase=TEST_BY_ID[test_id]["title"])
        codes = [self._wait(*main)]
        if companion:
            if not self.cancel_event.is_set() and companion[0].poll() is None:
                self._set(phase="Completando carga simultánea")
                self._log("sistema", "La simulación terminó; esperando el resumen de carga")
            codes.append(self._wait(*companion))
        return codes

    def _prepare(self, test_id, params):
        context = {}
        if test_id == "node_failure":
            result = subprocess.run(
                [
                    "kubectl", "-n", "vibe", "get", "pods",
                    f"--field-selector=spec.nodeName={params['node']}", "-o", "json",
                ],
                cwd=VIBE_DIR, capture_output=True, text=True, timeout=20,
            )
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or "No se pudo inspeccionar el nodo elegido")
            items = json.loads(result.stdout).get("items", [])
            stateless_apps = sorted({
                pod.get("metadata", {}).get("labels", {}).get("app")
                for pod in items
                if pod.get("metadata", {}).get("labels", {}).get("app") in STATELESS_APPS
                and not pod.get("metadata", {}).get("deletionTimestamp")
            })
            if not stateless_apps:
                raise RuntimeError(
                    f"{params['node']} no aloja pods stateless en este momento. "
                    "Recarga el panel y elige el nodo recomendado."
                )
            stateful = []
            for pod in items:
                volumes = pod.get("spec", {}).get("volumes", [])
                claims = [
                    volume["persistentVolumeClaim"]["claimName"]
                    for volume in volumes if "persistentVolumeClaim" in volume
                ]
                owners = pod.get("metadata", {}).get("ownerReferences", [])
                is_stateful = claims or any(owner.get("kind") == "StatefulSet" for owner in owners)
                if is_stateful:
                    name = pod.get("metadata", {}).get("name", "pod desconocido")
                    detail = f" (PVC: {', '.join(claims)})" if claims else ""
                    stateful.append(f"{name}{detail}")
            if stateful:
                self._log(
                    "sistema",
                    f"ADVERTENCIA: {params['node']} aloja servicios con estado: "
                    f"{'; '.join(stateful)}. También estarán inaccesibles mientras el nodo permanezca apagado.",
                )
        elif test_id == "rolling":
            result = subprocess.run(
                ["kubectl", "-n", "vibe", "get", "deployment/frontend", "-o", "jsonpath={.spec.template.spec.containers[0].image}"],
                cwd=VIBE_DIR, capture_output=True, text=True, timeout=20,
            )
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or "No se pudo consultar la imagen del frontend")
            context["original_image"] = result.stdout.strip()
        return context

    def _cleanup(self, test_id, params, context, abnormal):
        try:
            if test_id == "node_failure":
                subprocess.run(["docker", "start", params["node"]], capture_output=True, timeout=30, cwd=VIBE_DIR)
            elif test_id == "rolling" and context.get("original_image"):
                subprocess.run(
                    ["kubectl", "-n", "vibe", "set", "image", "deployment/frontend", f"frontend={context['original_image']}"],
                    capture_output=True, timeout=30, cwd=VIBE_DIR,
                )
                subprocess.run(
                    ["kubectl", "-n", "vibe", "rollout", "status", "deployment/frontend", "--timeout=180s"],
                    capture_output=True, timeout=190, cwd=VIBE_DIR,
                )
            elif test_id == "oom" and abnormal:
                subprocess.run(["make", "--silent", "chaos-oom-restore"], capture_output=True, timeout=190, cwd=VIBE_DIR)
        except Exception as exc:  # noqa: BLE001
            self._log("sistema", f"Aviso durante restauración: {exc}")

    def _artifacts(self, started):
        root = VIBE_DIR / "docs" / "evidencia"
        if not root.is_dir():
            return []
        return [
            p.name for p in sorted(root.iterdir(), key=lambda item: item.stat().st_mtime, reverse=True)
            if p.is_file() and p.stat().st_mtime >= started - 1
        ][:50]

    def _run(self, test_id, params):
        codes, context = [], {}
        final_status, final_outcome, final_error = "failed", "error", None
        try:
            self._set(status="running", phase="Validando entorno")
            context = self._prepare(test_id, params)
            repetitions = params.get("repetitions", 1)
            for repetition in range(1, repetitions + 1):
                if self.cancel_event.is_set():
                    break
                codes.extend(self._run_once(test_id, params, repetition, repetitions))
            cancelled = self.cancel_event.is_set()
            hard_failures = [code for code in codes if code not in (0, 99, 130)]
            if cancelled:
                final_status, final_outcome = "cancelled", "cancelled"
            elif hard_failures:
                final_status, final_outcome = "failed", "error"
            elif 99 in codes:
                final_status, final_outcome = "completed", "slo_failed"
            else:
                final_status, final_outcome = "completed", "passed"
        except Exception as exc:  # noqa: BLE001
            self._log("sistema", f"Error: {exc}")
            final_status = "cancelled" if self.cancel_event.is_set() else "failed"
            final_outcome = "cancelled" if self.cancel_event.is_set() else "error"
            final_error = str(exc)
        finally:
            abnormal = self.cancel_event.is_set() or final_status == "failed"
            self._set(status="stopping" if self.cancel_event.is_set() else "running", phase="Restaurando entorno")
            self._cleanup(test_id, params, context, abnormal)
            if self.cancel_event.is_set():
                final_status, final_outcome = "cancelled", "cancelled"
            with self.lock:
                if self.current:
                    ended = time.time()
                    self.current.update({
                        "status": final_status, "outcome": final_outcome,
                        "exit_code": max(codes) if codes else (130 if final_status == "cancelled" else 1 if final_status == "failed" else 0),
                        "error": final_error, "phase": "Finalizada",
                        "ended_at": datetime.now().isoformat(timespec="seconds"), "ended_epoch": ended,
                        "artifacts": self._artifacts(self.current["started_epoch"]),
                    })
                    summary = {k: v for k, v in self.current.items() if k not in {"started_epoch", "ended_epoch"}}
                    self.history.appendleft(summary)

    def _terminate_tree(self, proc):
        if proc.poll() is not None:
            return
        try:
            if os.name == "nt":
                proc.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except Exception:  # noqa: BLE001
            pass
        try:
            proc.wait(timeout=4)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=15)
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception as exc:  # noqa: BLE001
            self._log("sistema", f"No se pudo cerrar un proceso: {exc}")

    def stop(self):
        with self.lock:
            if not self.current or self.current["status"] not in {"starting", "running", "stopping"}:
                raise RuntimeError("No hay una prueba en ejecución")
            self.current.update({"status": "stopping", "phase": "Deteniendo y restaurando"})
            self.cancel_event.set()
            processes = list(self.processes.values())
        self._log("sistema", "Cancelación solicitada")
        for proc in processes:
            self._terminate_tree(proc)
        return self.status()["current"]

    def shutdown(self):
        with self.lock:
            active = self.current and self.current["status"] in {"starting", "running", "stopping"}
        if active:
            try:
                self.stop()
            except Exception:  # noqa: BLE001
                pass


TEST_MANAGER = TestManager()


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
            "node": p["spec"].get("nodeName", ""), "state": state,
            "ready": not p["metadata"].get("deletionTimestamp") and any(
                c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", [])
            ),
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
    api_ports = {"api": 8000, "catalog-api": 8000, "upload-api": 8001, "stream-api": 8002}
    api_pods = [p for p in pods if p["app"] in api_ports and p["ready"]]
    with ThreadPoolExecutor(8) as ex:
        futs = {p["name"]: ex.submit(pod_metrics, ns, p["name"], api_ports[p["app"]]) for p in api_pods}
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
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, value):
        self.send(code, json.dumps(value, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def read_json(self):
        ctype = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            raise ValueError("Content-Type debe ser application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Content-Length inválido") from exc
        if length < 1 or length > 65536:
            raise ValueError("Cuerpo vacío o demasiado grande")
        try:
            value = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            raise ValueError("JSON inválido") from exc
        if not isinstance(value, dict):
            raise ValueError("El cuerpo debe ser un objeto JSON")
        return value

    def do_GET(self):
        if self.path.startswith("/api/cluster"):
            self.send_json(200, {"data": STATE["data"], "error": STATE["error"], "script": STATE["script"]})
        elif self.path == "/api/tests/catalog":
            self.send_json(200, {"tests": test_catalog_view()})
        elif self.path == "/api/tests/status":
            self.send_json(200, TEST_MANAGER.status())
        elif self.path == "/" or self.path.startswith("/index"):
            self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        else:
            self.send(404, b"not found", "text/plain")

    def do_POST(self):
        try:
            payload = self.read_json()
            if self.path == "/api/tests/start":
                test_id = payload.get("test_id")
                if not isinstance(test_id, str):
                    raise ValueError("Falta test_id")
                current = TEST_MANAGER.start(test_id, payload.get("params", {}))
                self.send_json(202, {"current": current})
            elif self.path == "/api/tests/stop":
                current = TEST_MANAGER.stop()
                self.send_json(202, {"current": current})
            else:
                self.send_json(404, {"error": "Ruta no encontrada"})
        except ValueError as exc:
            self.send_json(400, {"error": str(exc)})
        except RuntimeError as exc:
            self.send_json(409, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            self.send_json(500, {"error": str(exc)})


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
    finally:
        TEST_MANAGER.shutdown()


if __name__ == "__main__":
    main()
