#!/usr/bin/env python3
"""Ejecuta una corrida P2 y guarda evidencia reproducible de k6 y Kubernetes."""

import argparse
import csv
import html
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import urlopen


SCENARIOS = {
    "load": {
        "script": "tests/k6/load.js",
        "prefix": "carga-300",
        "users": 300,
        "capture_at": 300,
    },
    "stress": {
        "script": "tests/k6/stress.js",
        "prefix": "estres-1500",
        "users": 1500,
        "capture_at": 360,
    },
    "spike": {
        "script": "tests/k6/spike.js",
        "prefix": "spike-1000",
        "users": 1000,
        "capture_at": 100,
    },
}

DEPLOYMENTS = ("catalog-api", "upload-api", "stream-api")
BASE_REPLICAS = {"catalog-api": 2, "upload-api": 2, "stream-api": 2}
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def run(command: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def kubectl_json(*args: str) -> dict:
    result = run(["kubectl", *args, "-o", "json"])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "kubectl falló")
    return json.loads(result.stdout)


def api_stats(api: str) -> dict:
    with urlopen(f"{api}/api/stats", timeout=10) as response:
        return json.load(response)


def cluster_state() -> dict:
    deployments_raw = kubectl_json("-n", "vibe", "get", "deployment")
    hpas_raw = kubectl_json("-n", "vibe", "get", "hpa")
    pods_raw = kubectl_json("-n", "vibe", "get", "pods")

    deployments = {}
    for item in deployments_raw["items"]:
        name = item["metadata"]["name"]
        if name not in DEPLOYMENTS:
            continue
        status = item.get("status", {})
        deployments[name] = {
            "desired": item.get("spec", {}).get("replicas", 0),
            "current": status.get("replicas", 0),
            "ready": status.get("readyReplicas", 0),
            "available": status.get("availableReplicas", 0),
        }

    hpas = {}
    for item in hpas_raw["items"]:
        target = item["spec"]["scaleTargetRef"]["name"]
        if target not in DEPLOYMENTS:
            continue
        status = item.get("status", {})
        cpu = None
        for metric in status.get("currentMetrics", []):
            if metric.get("type") == "Resource" and metric["resource"].get("name") == "cpu":
                cpu = metric["resource"].get("current", {}).get("averageUtilization")
        hpas[target] = {
            "current": status.get("currentReplicas", 0),
            "desired": status.get("desiredReplicas", 0),
            "cpu_percent": cpu,
        }

    pods_clean = True
    pod_count = 0
    for pod in pods_raw["items"]:
        pod_count += 1
        deleting = bool(pod["metadata"].get("deletionTimestamp"))
        ready = any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in pod.get("status", {}).get("conditions", [])
        )
        if deleting or pod.get("status", {}).get("phase") != "Running" or not ready:
            pods_clean = False

    return {
        "deployments": deployments,
        "hpas": hpas,
        "pods_clean": pods_clean,
        "pod_count": pod_count,
    }


def is_baseline(state: dict) -> bool:
    if not state["pods_clean"]:
        return False
    for name, expected in BASE_REPLICAS.items():
        deployment = state["deployments"].get(name, {})
        if deployment.get("desired") != expected or deployment.get("ready") != expected:
            return False
    return True


def wait_for_baseline(api: str, timeout: int) -> tuple[dict, dict]:
    deadline = time.monotonic() + timeout
    last_state = {}
    last_stats = {}
    while time.monotonic() < deadline:
        last_state = cluster_state()
        last_stats = api_stats(api)
        queue_clean = (
            last_stats.get("queue_length") == 0
            and last_stats.get("pending") == 0
            and last_stats.get("processing") == 0
            and last_stats.get("ready", 0) > 0
        )
        if is_baseline(last_state) and queue_clean:
            return last_state, last_stats
        time.sleep(5)
    raise TimeoutError(
        f"El clúster no volvió a estado limpio. Estado={last_state}, stats={last_stats}"
    )


def write_cluster_snapshot(path: Path) -> None:
    commands = [
        ["kubectl", "-n", "vibe", "get", "pods", "-o", "wide"],
        ["kubectl", "-n", "vibe", "get", "hpa"],
        ["kubectl", "-n", "vibe", "top", "pods"],
    ]
    blocks = []
    for command in commands:
        result = run(command)
        blocks.append(f"$ {' '.join(command)}\n{result.stdout}{result.stderr}")
    path.write_text("\n".join(blocks), encoding="utf-8")


def flatten_sample(elapsed: float, state: dict) -> dict:
    row = {"elapsed_seconds": round(elapsed, 3)}
    for name in DEPLOYMENTS:
        deployment = state["deployments"].get(name, {})
        hpa = state["hpas"].get(name, {})
        row[f"{name}_desired"] = deployment.get("desired")
        row[f"{name}_ready"] = deployment.get("ready")
        row[f"{name}_cpu_percent"] = hpa.get("cpu_percent")
        row[f"{name}_hpa_desired"] = hpa.get("desired")
    return row


def start_peak_captures(prefix: Path) -> list[subprocess.Popen]:
    node_script = str(Path("tools/capture_evidence.mjs"))
    jobs = []
    for kind, suffix in (("k8sweb", "k8sweb"), ("grafana", "grafana")):
        output = str(prefix.with_name(prefix.name + f"-{suffix}.png"))
        jobs.append(
            subprocess.Popen(
                ["node", node_script, "--kind", kind, "--output", output],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        )
    return jobs


def wait_captures(jobs: list[subprocess.Popen]) -> list[dict]:
    results = []
    for job in jobs:
        try:
            _, stderr = job.communicate(timeout=60)
            results.append({"exit_code": job.returncode, "error": stderr.strip()})
        except subprocess.TimeoutExpired:
            job.kill()
            _, stderr = job.communicate()
            results.append({"exit_code": -1, "error": f"timeout; {stderr.strip()}"})
    return results


def metric_values(raw: dict, name: str) -> dict:
    metric = raw.get("metrics", {}).get(name, {})
    # k6 <=0.49 nested these under `values`; current k6 exports them directly.
    return metric.get("values", metric)


def make_terminal_capture(log_path: Path, html_path: Path, png_path: Path) -> int:
    text = ANSI.sub("", log_path.read_text(encoding="utf-8", errors="replace"))
    text = text.replace("\r", "\n")
    lines = [line for line in text.splitlines() if line.strip()]
    # Keep the final k6 summary visible inside the fixed 1600x1000 evidence frame.
    excerpt = "\n".join(lines[-38:])
    document = f"""<!doctype html><meta charset=\"utf-8\"><title>k6</title>
<style>
body{{margin:0;background:#111827;color:#e5e7eb;font:15px/1.35 Consolas,monospace}}
header{{padding:16px 24px;background:#172033;color:#60a5fa;font:bold 22px system-ui}}
pre{{white-space:pre-wrap;margin:0;padding:22px 26px}}
</style><header>VIBE · k6 · {html.escape(log_path.stem)}</header><pre>{html.escape(excerpt)}</pre>"""
    html_path.write_text(document, encoding="utf-8")
    result = run(
        [
            "node",
            "tools/capture_evidence.mjs",
            "--kind",
            "url",
            "--url",
            html_path.resolve().as_uri(),
            "--output",
            str(png_path),
            "--wait",
            "1500",
        ],
        timeout=30,
    )
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=SCENARIOS)
    parser.add_argument("--run", type=int, choices=(1, 2, 3), required=True)
    parser.add_argument("--api", default="http://localhost")
    parser.add_argument("--poll", type=float, default=5.0)
    parser.add_argument("--baseline-timeout", type=int, default=600)
    parser.add_argument("--evidence", default="docs/evidencia")
    args = parser.parse_args()

    config = SCENARIOS[args.scenario]
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    prefix = evidence / f"{config['prefix']}-{args.run}"
    log_path = prefix.with_name(prefix.name + "-k6.txt")
    raw_summary_path = prefix.with_name(prefix.name + "-k6.json")
    k6_png_path = prefix.with_name(prefix.name + "-k6.png")
    k6_html_path = prefix.with_name(prefix.name + "-k6.html")
    timeline_path = prefix.with_name(prefix.name + "-k8s.csv")
    summary_path = prefix.with_name(prefix.name + "-resumen.json")
    before_path = prefix.with_name(prefix.name + "-cluster-inicio.txt")
    after_path = prefix.with_name(prefix.name + "-cluster-final.txt")

    initial_state, initial_stats = wait_for_baseline(args.api, args.baseline_timeout)
    write_cluster_snapshot(before_path)

    started_utc = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    command = [
        "k6",
        "run",
        "--summary-export",
        str(raw_summary_path),
        "-e",
        f"BASE_URL={args.api}",
        config["script"],
    ]
    capture_jobs: list[subprocess.Popen] = []
    capture_started = False
    samples = []
    max_replicas = {name: BASE_REPLICAS[name] for name in DEPLOYMENTS}
    first_scale = {name: None for name in DEPLOYMENTS}

    with log_path.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
            env=os.environ.copy(),
        )
        while process.poll() is None:
            elapsed = time.monotonic() - started
            state = cluster_state()
            samples.append(flatten_sample(elapsed, state))
            for name in DEPLOYMENTS:
                desired = state["deployments"].get(name, {}).get("desired", 0)
                max_replicas[name] = max(max_replicas[name], desired)
                if first_scale[name] is None and desired > BASE_REPLICAS[name]:
                    first_scale[name] = elapsed
            if not capture_started and elapsed >= config["capture_at"]:
                capture_jobs = start_peak_captures(prefix)
                capture_started = True
            time.sleep(args.poll)
        k6_exit_code = process.returncode

    ended = time.monotonic()
    end_state = cluster_state()
    capture_results = wait_captures(capture_jobs) if capture_jobs else []
    terminal_capture_exit = make_terminal_capture(log_path, k6_html_path, k6_png_path)
    settled_started = time.monotonic()
    final_state, final_stats = wait_for_baseline(args.api, args.baseline_timeout)
    settled_seconds = time.monotonic() - settled_started
    write_cluster_snapshot(after_path)

    if samples:
        with timeline_path.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=samples[0].keys())
            writer.writeheader()
            writer.writerows(samples)

    raw = (
        json.loads(raw_summary_path.read_text(encoding="utf-8"))
        if raw_summary_path.exists()
        else {}
    )
    duration = metric_values(raw, "http_req_duration")
    failed = metric_values(raw, "http_req_failed")
    requests = metric_values(raw, "http_reqs")
    error_rate = failed.get("rate", failed.get("value"))
    p95 = duration.get("p(95)")
    summary = {
        "scenario": args.scenario,
        "users": config["users"],
        "run": args.run,
        "started_utc": started_utc,
        "duration_seconds": round(ended - started, 3),
        "k6_exit_code": k6_exit_code,
        "thresholds_passed": k6_exit_code == 0,
        "http_requests": requests.get("count"),
        "requests_per_second": requests.get("rate"),
        "p50_ms": duration.get("p(50)", duration.get("med")),
        "p95_ms": p95,
        "p99_ms": duration.get("p(99)"),
        "error_rate": error_rate,
        "error_percent": error_rate * 100 if error_rate is not None else None,
        "slo_met": bool(p95 is not None and error_rate is not None and p95 < 500 and error_rate < 0.01),
        "initial_stats": initial_stats,
        "max_replicas": max_replicas,
        "first_scale_seconds": {
            name: round(value, 3) if value is not None else None
            for name, value in first_scale.items()
        },
        "replicas_at_k6_end": {
            name: end_state["deployments"].get(name, {}).get("desired")
            for name in DEPLOYMENTS
        },
        "settled_after_k6_seconds": round(settled_seconds, 3),
        "final_stats": final_stats,
        "capture_results": capture_results,
        "terminal_capture_exit_code": terminal_capture_exit,
        "completed": bool(raw_summary_path.exists() and samples),
    }
    summary_path.write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if summary["completed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
