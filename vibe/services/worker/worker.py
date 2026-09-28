"""
VIBE Transcoder Worker.

Consume trabajos de una lista de Redis (BLPOP), descarga el audio original de MinIO/S3,
lo convierte a HLS en dos bitrates (64k y 128k) con ffmpeg, calcula la forma de onda
y sube todo al bucket "hls". Un trabajo a la vez por pod: así KEDA tiene que crear
más pods cuando la cola crece.
"""
import array
import json
import logging
import os
import platform
import shutil
import signal
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import redis
from minio import Minio
from prometheus_client import Counter, Gauge, Histogram, start_http_server
from sqlalchemy import create_engine, text

logging.basicConfig(level=logging.INFO, format="%(asctime)s worker %(levelname)s %(message)s")
log = logging.getLogger("vibe.worker")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+psycopg://vibe:vibe@localhost:5432/vibe")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "vibeadmin")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "vibesecret123")
MINIO_SESSION_TOKEN = os.getenv("MINIO_SESSION_TOKEN", "") or None
MINIO_SECURE = os.getenv("MINIO_SECURE", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

BUCKET_RAW = os.getenv("BUCKET_RAW", "raw")
BUCKET_HLS = os.getenv("BUCKET_HLS", "hls")
QUEUE_NAME = os.getenv("QUEUE_NAME", "transcode")

try:
    _node = os.uname().nodename
except AttributeError:
    _node = platform.node()
POD_NAME = os.getenv("POD_NAME", _node)

METRICS_PORT = int(os.getenv("METRICS_PORT", "9100"))
SEGMENT_SECONDS = os.getenv("HLS_SEGMENT_SECONDS", "6")
BITRATES = [b.strip() for b in os.getenv("HLS_BITRATES", "64k,128k").split(",") if b.strip()]
WAVEFORM_POINTS = int(os.getenv("WAVEFORM_POINTS", "120"))

JOBS = Counter("vibe_worker_jobs_total", "Trabajos procesados", ["result"])
JOB_TIME = Histogram("vibe_worker_job_seconds", "Duración de cada transcodificación")
BUSY = Gauge("vibe_worker_busy", "1 si el worker está procesando")

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
r = redis.Redis.from_url(REDIS_URL, decode_responses=True)

_client_kwargs = {
    "endpoint": MINIO_ENDPOINT,
    "access_key": MINIO_ACCESS_KEY,
    "secret_key": MINIO_SECRET_KEY,
    "secure": MINIO_SECURE,
}
if MINIO_SESSION_TOKEN:
    _client_kwargs["session_token"] = MINIO_SESSION_TOKEN
if AWS_REGION:
    _client_kwargs["region"] = AWS_REGION

minio = Minio(**_client_kwargs)

running = True


def stop(*_):
    global running
    running = False
    log.info("Señal recibida, termino el trabajo actual y salgo")


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


# ---------- helpers ----------
def now():
    return datetime.now(timezone.utc)


def set_status(track_id: str, status: str, **fields):
    sets = ", ".join(f"{k} = :{k}" for k in fields)
    sql = f"UPDATE tracks SET status = :status, updated_at = :updated_at{', ' + sets if sets else ''} WHERE id = :id"
    with engine.begin() as conn:
        conn.execute(text(sql), {"status": status, "updated_at": now(), "id": track_id, **fields})


def fetch_track(track_id: str):
    with engine.connect() as conn:
        row = conn.execute(text("SELECT id, raw_key FROM tracks WHERE id = :id"), {"id": track_id}).mappings().first()
    return dict(row) if row else None


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{cmd[0]} falló: {proc.stderr[-800:]}")
    return proc.stdout


def probe_duration(path: Path) -> float:
    out = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)])
    return float(out.strip() or 0)


def waveform(path: Path, points: int) -> list[float]:
    """Picos normalizados 0..1 para dibujar la onda en el player."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg waveform falló: {proc.stderr[-800:].decode(errors='ignore')}")
    samples = array.array("h")
    samples.frombytes(proc.stdout[: len(proc.stdout) - (len(proc.stdout) % 2)])
    n = len(samples)
    if n == 0:
        return [0.0] * points
    bucket = max(1, n // points)
    peaks = []
    for i in range(points):
        chunk = samples[i * bucket : (i + 1) * bucket]
        peaks.append(max((abs(s) for s in chunk), default=0))
    top = max(peaks) or 1
    return [round(p / top, 3) for p in peaks]


def transcode_hls(src: Path, out_dir: Path) -> None:
    for br in BITRATES:
        d = out_dir / br
        d.mkdir(parents=True, exist_ok=True)
        run([
            "ffmpeg", "-v", "error", "-y", "-i", str(src), "-vn",
            "-c:a", "aac", "-b:a", br, "-ac", "2",
            "-hls_time", SEGMENT_SECONDS, "-hls_playlist_type", "vod", "-hls_list_size", "0",
            "-hls_segment_filename", str(d / "seg_%03d.ts"),
            str(d / "index.m3u8"),
        ])
    lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
    for br in BITRATES:
        kbps = int(br.rstrip("k"))
        lines.append(f'#EXT-X-STREAM-INF:BANDWIDTH={int(kbps * 1000 * 1.25)},CODECS="mp4a.40.2",NAME="{br}"')
        lines.append(f"{br}/index.m3u8")
    (out_dir / "master.m3u8").write_text("\n".join(lines) + "\n")


def upload_dir(local: Path, prefix: str) -> None:
    types = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t"}
    for p in local.rglob("*"):
        if p.is_file():
            key = f"{prefix}/{p.relative_to(local).as_posix()}"
            minio.fput_object(BUCKET_HLS, key, str(p), content_type=types.get(p.suffix, "application/octet-stream"))


# ---------- trabajo ----------
def process(track_id: str) -> None:
    track = fetch_track(track_id)
    if not track:
        log.warning("Track %s no existe, se descarta", track_id)
        return
    set_status(track_id, "processing", worker=POD_NAME, error=None)
    tmp = Path(tempfile.mkdtemp(prefix="vibe-"))
    try:
        src = tmp / ("original" + Path(track["raw_key"]).suffix)
        minio.fget_object(BUCKET_RAW, track["raw_key"], str(src))

        duration = probe_duration(src)
        peaks = waveform(src, WAVEFORM_POINTS)
        out = tmp / "hls"
        transcode_hls(src, out)

        prefix = f"tracks/{track_id}"
        upload_dir(out, prefix)
        set_status(track_id, "ready", duration_sec=duration, hls_prefix=prefix, waveform=json.dumps(peaks))
        log.info("Track %s listo (%.1fs, %s)", track_id, duration, ",".join(BITRATES))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> None:
    start_http_server(METRICS_PORT)
    log.info("Worker %s escuchando cola '%s'", POD_NAME, QUEUE_NAME)
    while running:
        try:
            item = r.blpop(QUEUE_NAME, timeout=5)
        except redis.RedisError as exc:
            log.warning("Redis: %s", exc)
            time.sleep(2)
            continue
        if not item:
            continue
        job = json.loads(item[1])
        track_id = job["track_id"]
        BUSY.set(1)
        t0 = time.time()
        try:
            process(track_id)
            JOBS.labels("ok").inc()
        except Exception as exc:  # noqa: BLE001
            log.exception("Fallo en track %s", track_id)
            JOBS.labels("error").inc()
            try:
                set_status(track_id, "failed", error=str(exc)[:1000])
            except Exception:  # noqa: BLE001
                log.exception("No se pudo marcar como failed")
        finally:
            JOB_TIME.observe(time.time() - t0)
            BUSY.set(0)
    log.info("Worker detenido")


if __name__ == "__main__":
    main()
