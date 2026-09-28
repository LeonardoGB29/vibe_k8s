import logging
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator

import config
import storage

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("vibe.stream-api")

CONTENT_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".ts": "video/mp2t",
    ".aac": "audio/aac",
    ".json": "application/json",
}

STREAM_BYTES = Counter("vibe_stream_bytes_total", "Bytes servidos por streaming")
SEGMENTS = Counter("vibe_stream_segments_total", "Segmentos HLS servidos")

app = FastAPI(title="VIBE Stream API", version="1.0.0")
Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz"]).instrument(app).expose(app)


@app.middleware("http")
async def add_pod_header(request, call_next):
    response = await call_next(request)
    response.headers["X-Served-By"] = config.POD_NAME
    return response


# ---------- Salud ----------
@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "stream-api", "pod": config.POD_NAME}


@app.get("/readyz")
def readyz():
    try:
        storage.client.bucket_exists(config.BUCKET_HLS)
    except Exception as exc:  # noqa: BLE001
        return JSONResponse({"status": "not ready", "error": str(exc)}, status_code=503)
    return {"status": "ready", "service": "stream-api", "pod": config.POD_NAME}


# ---------- Streaming HLS ----------
@app.get("/stream/{track_id}/{path:path}")
def stream(track_id: str, path: str):
    if ".." in path or path.startswith("/"):
        raise HTTPException(400, "Ruta inválida")
    key = f"tracks/{track_id}/{path}"
    obj = storage.get_object(config.BUCKET_HLS, key)
    if obj is None:
        raise HTTPException(404, "Segmento no encontrado")

    ext = Path(path).suffix.lower()
    content_type = CONTENT_TYPES.get(ext, "application/octet-stream")
    if ext == ".ts":
        SEGMENTS.inc()

    def iterfile():
        try:
            for chunk in obj.stream(128 * 1024):
                STREAM_BYTES.inc(len(chunk))
                yield chunk
        finally:
            obj.close()
            obj.release_conn()

    headers = {"Cache-Control": "public, max-age=3600" if ext == ".ts" else "no-cache"}
    return StreamingResponse(iterfile(), media_type=content_type, headers=headers)
