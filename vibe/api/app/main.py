import logging
import os
import shutil
import tempfile
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import config, queue, storage
from .db import Base, engine, get_session, wait_for_db
from .models import Track
from .schemas import Stats, TrackOut

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("vibe.api")

STATIC_DIR = Path(__file__).parent / "static"
ALLOWED_EXT = {".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac"}
CONTENT_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".ts": "video/mp2t",
    ".aac": "audio/aac",
    ".json": "application/json",
}

UPLOADS = Counter("vibe_uploads_total", "Audios subidos")
STREAM_BYTES = Counter("vibe_stream_bytes_total", "Bytes servidos por streaming")
SEGMENTS = Counter("vibe_stream_segments_total", "Segmentos HLS servidos")


@asynccontextmanager
async def lifespan(app: FastAPI):
    wait_for_db()
    Base.metadata.create_all(engine)
    storage.ensure_buckets()
    log.info("API lista en pod %s", config.POD_NAME)
    yield


app = FastAPI(title="VIBE API", version="1.0.0", lifespan=lifespan)
Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz", "/static/.*"]).instrument(app).expose(app)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.middleware("http")
async def add_pod_header(request, call_next):
    response = await call_next(request)
    response.headers["X-Served-By"] = config.POD_NAME
    return response


# ---------- Frontend ----------
@app.get("/", include_in_schema=False)
def index():
    return FileResponse(STATIC_DIR / "index.html")


# ---------- Salud ----------
@app.get("/healthz")
def healthz():
    return {"status": "ok", "pod": config.POD_NAME}


@app.get("/readyz")
def readyz(db: Session = Depends(get_session)):
    try:
        db.execute(select(1))
        queue.ping()
    except Exception as exc:  # noqa: BLE001
        return JSONResponse({"status": "not ready", "error": str(exc)}, status_code=503)
    return {"status": "ready", "pod": config.POD_NAME}


# ---------- Catálogo ----------
@app.get("/api/tracks", response_model=list[TrackOut])
def list_tracks(q: str | None = None, status: str | None = None, limit: int = 200, db: Session = Depends(get_session)):
    stmt = select(Track).order_by(Track.created_at.desc()).limit(min(limit, 1000))
    if q:
        like = f"%{q}%"
        stmt = stmt.where((Track.title.ilike(like)) | (Track.artist.ilike(like)) | (Track.album.ilike(like)))
    if status:
        stmt = stmt.where(Track.status == status)
    return [TrackOut.from_model(t) for t in db.scalars(stmt)]


@app.get("/api/tracks/{track_id}", response_model=TrackOut)
def get_track(track_id: str, db: Session = Depends(get_session)):
    track = db.get(Track, track_id)
    if not track:
        raise HTTPException(404, "Track no encontrado")
    return TrackOut.from_model(track)


@app.post("/api/tracks", response_model=TrackOut, status_code=201)
def upload_track(
    file: UploadFile = File(...),
    title: str | None = Form(None),
    artist: str = Form("Desconocido"),
    album: str = Form("Single"),
    db: Session = Depends(get_session),
):
    ext = Path(file.filename or "").suffix.lower()
    if ext not in ALLOWED_EXT:
        raise HTTPException(400, f"Formato no soportado: {ext or 'sin extensión'}")

    track_id = str(uuid.uuid4())
    raw_key = f"tracks/{track_id}/original{ext}"

    with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
        shutil.copyfileobj(file.file, tmp, length=1024 * 1024)
        tmp_path = tmp.name
    try:
        size_mb = os.path.getsize(tmp_path) / (1024 * 1024)
        if size_mb > config.MAX_UPLOAD_MB:
            raise HTTPException(413, f"Archivo demasiado grande ({size_mb:.1f} MB)")
        storage.put_file(config.BUCKET_RAW, raw_key, tmp_path, file.content_type or "application/octet-stream")
    finally:
        os.unlink(tmp_path)

    track = Track(
        id=track_id,
        title=(title or Path(file.filename or "Sin título").stem).strip()[:200],
        artist=artist.strip()[:200] or "Desconocido",
        album=album.strip()[:200] or "Single",
        raw_key=raw_key,
        status="pending",
    )
    db.add(track)
    db.commit()
    queue.enqueue(track_id)
    UPLOADS.inc()
    return TrackOut.from_model(track)


@app.delete("/api/tracks/{track_id}", status_code=204)
def delete_track(track_id: str, db: Session = Depends(get_session)):
    track = db.get(Track, track_id)
    if not track:
        raise HTTPException(404, "Track no encontrado")
    storage.delete_key(config.BUCKET_RAW, track.raw_key)
    if track.hls_prefix:
        storage.delete_prefix(config.BUCKET_HLS, track.hls_prefix)
    db.delete(track)
    db.commit()


@app.get("/api/stats", response_model=Stats)
def stats(db: Session = Depends(get_session)):
    rows = db.execute(select(Track.status, func.count()).group_by(Track.status)).all()
    counts = {status: n for status, n in rows}
    return Stats(
        pod=config.POD_NAME,
        queue_length=queue.queue_length(),
        pending=counts.get("pending", 0),
        processing=counts.get("processing", 0),
        ready=counts.get("ready", 0),
        failed=counts.get("failed", 0),
        total=sum(counts.values()),
    )


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
