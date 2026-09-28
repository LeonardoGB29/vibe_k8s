import logging
import os
import shutil
import tempfile
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import select
from sqlalchemy.orm import Session

import config
from db import Base, engine, get_session, wait_for_db
from models import Track
import queue
from schemas import TrackOut
import storage

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("vibe.upload-api")

ALLOWED_EXT = {".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac"}
UPLOADS = Counter("vibe_uploads_total", "Audios subidos")


@asynccontextmanager
async def lifespan(app: FastAPI):
    wait_for_db()
    Base.metadata.create_all(engine)
    storage.ensure_buckets()
    log.info("Upload API lista en pod %s", config.POD_NAME)
    yield


app = FastAPI(title="VIBE Upload API", version="1.0.0", lifespan=lifespan)
Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz"]).instrument(app).expose(app)


@app.middleware("http")
async def add_pod_header(request, call_next):
    response = await call_next(request)
    response.headers["X-Served-By"] = config.POD_NAME
    return response


# ---------- Salud ----------
@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "upload-api", "pod": config.POD_NAME}


@app.get("/readyz")
def readyz(db: Session = Depends(get_session)):
    try:
        db.execute(select(1))
        queue.ping()
    except Exception as exc:  # noqa: BLE001
        return JSONResponse({"status": "not ready", "error": str(exc)}, status_code=503)
    return {"status": "ready", "service": "upload-api", "pod": config.POD_NAME}


# ---------- Upload ----------
def _process_upload(
    file: UploadFile,
    title: str | None,
    artist: str,
    album: str,
    db: Session,
) -> TrackOut:
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
        if os.path.exists(tmp_path):
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


@app.post("/api/upload", response_model=TrackOut, status_code=201)
def upload_endpoint(
    file: UploadFile = File(...),
    title: str | None = Form(None),
    artist: str = Form("Desconocido"),
    album: str = Form("Single"),
    db: Session = Depends(get_session),
):
    return _process_upload(file, title, artist, album, db)


# Alias para retrocompatibilidad con scripts existentes
@app.post("/api/tracks", response_model=TrackOut, status_code=201)
def upload_tracks_alias(
    file: UploadFile = File(...),
    title: str | None = Form(None),
    artist: str = Form("Desconocido"),
    album: str = Form("Single"),
    db: Session = Depends(get_session),
):
    return _process_upload(file, title, artist, album, db)
