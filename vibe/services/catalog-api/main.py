import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import func, select
from sqlalchemy.orm import Session

import config
from db import Base, engine, get_session, wait_for_db
from models import Track
import job_queue as queue
from schemas import Stats, TrackOut
import storage

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("vibe.catalog-api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    wait_for_db()
    Base.metadata.create_all(engine)
    log.info("Catalog API lista en pod %s", config.POD_NAME)
    yield


app = FastAPI(title="VIBE Catalog API", version="1.0.0", lifespan=lifespan)
Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz"]).instrument(app).expose(app)


@app.middleware("http")
async def add_pod_header(request, call_next):
    response = await call_next(request)
    response.headers["X-Served-By"] = config.POD_NAME
    return response


# ---------- Salud ----------
@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "catalog-api", "pod": config.POD_NAME}


@app.get("/readyz")
def readyz(db: Session = Depends(get_session)):
    try:
        db.execute(select(1))
        queue.ping()
    except Exception as exc:  # noqa: BLE001
        return JSONResponse({"status": "not ready", "error": str(exc)}, status_code=503)
    return {"status": "ready", "service": "catalog-api", "pod": config.POD_NAME}


# ---------- Catálogo ----------
@app.get("/api/tracks", response_model=list[TrackOut])
def list_tracks(
    q: str | None = None,
    status: str | None = None,
    limit: int = 200,
    db: Session = Depends(get_session),
):
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
