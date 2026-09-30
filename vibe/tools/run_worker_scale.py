#!/usr/bin/env python3
"""Run the upload workload and record Redis/KEDA worker scaling evidence."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.request import urlopen

from run_k6 import summarize as summarize_k6


NS = "vibe"
DEFAULT_AUDIO = Path("data/audio/001 - DJ Replica - Lunar Horizon.mp3")


def command(*args: str, timeout: int = 20, check: bool = True) -> str:
    result = subprocess.run(
        args,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def queue_length() -> int:
    value = command(
        "kubectl", "-n", NS, "exec", "deploy/redis", "--",
        "redis-cli", "LLEN", "transcode",
    )
    return int(value.splitlines()[-1])


def worker_state() -> tuple[int, int]:
    raw = command("kubectl", "-n", NS, "get", "deploy/worker", "-o", "json")
    data = json.loads(raw)
    return int(data["spec"].get("replicas", 0)), int(data["status"].get("readyReplicas", 0))


def api_stats(api: str) -> dict:
    with urlopen(f"{api.rstrip('/')}/api/stats", timeout=10) as response:
        return json.load(response)


def main() -> int:
    global NS
    parser = argparse.ArgumentParser()
    parser.add_argument("--ns", default=os.getenv("NS", "vibe"))
    parser.add_argument("--api", default="http://localhost")
    parser.add_argument("--uploads", type=int, default=200)
    parser.add_argument("--poll", type=float, default=2.0)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--audio", type=Path, default=DEFAULT_AUDIO)
    parser.add_argument("--evidence-dir", type=Path, default=Path("docs/evidencia"))
    args = parser.parse_args()
    if len(args.ns) > 63 or not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", args.ns):
        parser.error("ns debe ser un nombre de namespace Kubernetes válido")
    NS = args.ns

    if args.uploads < 1 or args.poll <= 0 or args.timeout < 1:
        parser.error("uploads, poll y timeout deben ser positivos")
    for executable in ("kubectl", "k6"):
        if not shutil.which(executable):
            parser.error(f"No se encontró {executable} en PATH")
    if not args.audio.is_file():
        parser.error(f"No existe {args.audio}; ejecuta make gen-audio")

    stats = api_stats(args.api)
    if queue_length() != 0 or stats.get("pending") or stats.get("processing"):
        parser.error("La cola debe empezar vacía; espera a que termine el worker")

    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    prefix = args.evidence_dir / f"worker-scale-{args.uploads}-{stamp}"
    log_path = prefix.with_name(prefix.name + "-k6.txt")
    raw_path = prefix.with_name(prefix.name + "-k6.json")
    csv_path = prefix.with_name(prefix.name + "-keda.csv")
    summary_path = prefix.with_name(prefix.name + "-resumen.json")

    env = os.environ.copy()
    env["UPLOADS"] = str(args.uploads)
    env["UPLOAD_FILE"] = str(args.audio.resolve())
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [
                "k6", "run", "--summary-export", str(raw_path),
                "-e", f"BASE_URL={args.api.rstrip('/')}",
                "tests/k6/upload.js",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )

        samples: list[dict] = []
        drained_since: float | None = None
        while time.monotonic() - started < args.timeout:
            elapsed = round(time.monotonic() - started, 3)
            try:
                desired, ready = worker_state()
                queued = queue_length()
                sample = {
                    "elapsed_seconds": elapsed,
                    "queue_length": queued,
                    "worker_desired": desired,
                    "worker_ready": ready,
                }
                samples.append(sample)
                print(json.dumps(sample), flush=True)
            except Exception as exc:  # keep the workload and preserve the gap
                print(f"Aviso al consultar KEDA: {exc}", file=sys.stderr, flush=True)
                queued = -1

            if process.poll() is not None and queued == 0:
                drained_since = drained_since or time.monotonic()
                if time.monotonic() - drained_since >= 10:
                    break
            else:
                drained_since = None
            time.sleep(args.poll)
        else:
            process.terminate()
            process.wait(timeout=15)
            raise RuntimeError(f"La prueba excedió {args.timeout}s")

    exit_code = process.wait()
    if not samples:
        raise RuntimeError("No se pudo obtener ninguna muestra de KEDA")
    with csv_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=samples[0].keys())
        writer.writeheader()
        writer.writerows(samples)

    scaled = [s for s in samples if s["worker_desired"] > 1]
    final_stats = api_stats(args.api)
    summary = {
        "uploads": args.uploads,
        "k6_exit_code": exit_code,
        "max_queue": max(s["queue_length"] for s in samples),
        "max_worker_desired": max(s["worker_desired"] for s in samples),
        "max_worker_ready": max(s["worker_ready"] for s in samples),
        "first_scale_seconds": scaled[0]["elapsed_seconds"] if scaled else None,
        "queue_drained": queue_length() == 0,
        "final_stats": final_stats,
        "files": {"k6_log": str(log_path), "timeline": str(csv_path), "k6_summary": str(raw_path)},
    }
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if raw_path.is_file():
        try:
            k6_summary = summarize_k6(json.loads(raw_path.read_text(encoding="utf-8")), "worker-scale", 20,
                                      time.monotonic() - started)
            results_dir = Path(__file__).resolve().parents[1] / "results" / "k6"
            results_dir.mkdir(parents=True, exist_ok=True)
            (results_dir / f"worker-scale-{stamp}.json").write_text(
                json.dumps(k6_summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        except (OSError, ValueError, TypeError) as exc:
            print(f"Aviso: no se pudo guardar el resumen k6 estructurado: {exc}", file=sys.stderr)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if exit_code == 0 and summary["queue_drained"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
