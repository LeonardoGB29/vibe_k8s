import logging
import json
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import func, select
from sqlalchemy.orm import Session, load_only

import config
from db import Base, engine, get_session, wait_for_db
from models import Track
import job_queue as queue
from schemas import Stats, TrackDetail, TrackListItem, TrackOut
import storage

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("vibe.catalog-api")

try:
    from prometheus_client import Counter, Gauge

    CATALOG_CACHE = Counter("vibe_catalog_cache_total", "Resultados de cache del catálogo", ["result"])
    DB_POOL_SIZE = Gauge("vibe_catalog_db_pool_size", "Conexiones base del pool SQLAlchemy")
    DB_POOL_CHECKED_OUT = Gauge("vibe_catalog_db_pool_checked_out", "Conexiones actualmente prestadas")
    DB_POOL_CHECKED_IN = Gauge("vibe_catalog_db_pool_checked_in", "Conexiones disponibles en el pool")
    DB_POOL_OVERFLOW = Gauge("vibe_catalog_db_pool_overflow", "Conexiones por encima del tamaño base")
    DB_POOL_CAPACITY = Gauge("vibe_catalog_db_pool_capacity", "Capacidad máxima configurada del pool")
    DB_POOL_SIZE.set_function(lambda: engine.pool.size())
    DB_POOL_CHECKED_OUT.set_function(lambda: engine.pool.checkedout())
    DB_POOL_CHECKED_IN.set_function(lambda: engine.pool.checkedin())
    DB_POOL_OVERFLOW.set_function(lambda: engine.pool.overflow())
    DB_POOL_CAPACITY.set(config.DB_POOL_SIZE + config.DB_MAX_OVERFLOW)
except (ImportError, AttributeError):
    log.warning("No se pudieron registrar métricas del pool SQLAlchemy")


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
@app.get("/api/tracks", response_model=list[TrackListItem])
def list_tracks(
    q: str | None = None,
    status: str | None = None,
    limit: int = 200,
    db: Session = Depends(get_session),
):
    limit = max(1, min(limit, 1000))
    cache_key = None
    try:
        version = queue.r.get("vibe:catalog:version") or "0"
        cache_key = f"vibe:catalog:v{version}:list:{limit}:{status or ''}:{q or ''}"
        cached = queue.r.get(cache_key)
        if cached:
            CATALOG_CACHE.labels("hit").inc()
            return json.loads(cached)
        CATALOG_CACHE.labels("miss").inc()
    except Exception as exc:  # noqa: BLE001 - Redis es optimización, no requisito
        log.debug("Cache de catálogo no disponible: %s", exc)
        try:
            CATALOG_CACHE.labels("error").inc()
        except NameError:
            pass
        cache_key = None

    stmt = select(Track).options(load_only(
        Track.id, Track.title, Track.artist, Track.album, Track.status,
        Track.duration_sec, Track.created_at,
    )).order_by(Track.created_at.desc()).limit(limit)
    if q:
        like = f"%{q}%"
        stmt = stmt.where((Track.title.ilike(like)) | (Track.artist.ilike(like)) | (Track.album.ilike(like)))
    if status:
        stmt = stmt.where(Track.status == status)
    result = [TrackListItem.from_model(t).model_dump(mode="json") for t in db.scalars(stmt)]
    if cache_key:
        try:
            queue.r.setex(cache_key, config.CATALOG_CACHE_TTL, json.dumps(result))
        except Exception as exc:  # noqa: BLE001
            log.debug("No se pudo guardar cache de catálogo: %s", exc)
    return result


@app.get("/api/tracks/{track_id}", response_model=TrackDetail)
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
    queue.invalidate_catalog()


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
