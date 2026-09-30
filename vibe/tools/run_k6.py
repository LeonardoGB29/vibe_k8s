#!/usr/bin/env python3
"""Run k6 normally and persist a compact, machine-readable test summary."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


def metric_value(metrics, name, key, default=None):
    return (metrics.get(name, {}).get("values", {}) or {}).get(key, default)


def threshold_results(metrics):
    results = []
    for entry in metrics.values():
        for result in (entry.get("thresholds", {}) or {}).values():
            if isinstance(result, dict) and isinstance(result.get("ok"), bool):
                results.append(result["ok"])
            elif isinstance(result, bool):
                results.append(result)
    return results


def summarize(data, name, vus, duration_seconds):
    metrics = data.get("metrics", {})
    reqs = metrics.get("http_reqs", {}).get("values", {}) or {}
    failed = metric_value(metrics, "http_req_failed", "rate", 0.0)
    duration = metrics.get("http_req_duration", {}).get("values", {}) or {}
    hls = metrics.get("hls_segment_ms", {}).get("values", {}) or {}
    threshold_checks = threshold_results(metrics)
    return {
        "name": name,
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "vus": vus or metric_value(metrics, "vus_max", "max") or {
            "load": 300, "stress": 1500, "spike": 1000, "ramp": 1200, "upload": 20,
        }.get(name),
        "duration_seconds": round(duration_seconds, 2),
        "requests": int(reqs.get("count", 0)),
        "requests_per_second": round(float(reqs.get("rate", 0)), 3),
        "error_rate": round(float(failed or 0), 6),
        "p50_ms": duration.get("med", duration.get("p(50)")),
        "p95_ms": duration.get("p(95)"),
        "p99_ms": duration.get("p(99)"),
        "hls_segment_p95_ms": hls.get("p(95)"),
        "thresholds_passed": all(threshold_checks) if threshold_checks else None,
        "thresholds": {
            metric: {key: value for key, value in (entry.get("thresholds", {}) or {}).items()}
            for metric, entry in metrics.items() if entry.get("thresholds")
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("script")
    args = parser.parse_args()
    if not shutil.which("k6"):
        print("No se encontró k6 en PATH", file=sys.stderr)
        return 127

    results_dir = Path(__file__).resolve().parents[1] / "results" / "k6"
    results_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="vibe-k6-") as tmp:
        summary_path = Path(tmp) / "summary.json"
        command = ["k6", "run", "--summary-export", str(summary_path)]
        for item in args.env:
            command.extend(["-e", item])
        command.append(args.script)
        result = subprocess.run(command, env=os.environ.copy())
        elapsed = time.monotonic() - started
        if summary_path.exists():
            try:
                data = json.loads(summary_path.read_text(encoding="utf-8"))
                vus = next((int(item.split("=", 1)[1]) for item in args.env if item.startswith("VUS=")), None)
                record = summarize(data, args.name, vus, elapsed)
                stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
                target = results_dir / f"{args.name}-{stamp}.json"
                target.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                print(f"Resumen k6 guardado: {target}")
            except (OSError, ValueError, TypeError) as exc:
                print(f"Aviso: no se pudo guardar el resumen estructurado: {exc}", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
