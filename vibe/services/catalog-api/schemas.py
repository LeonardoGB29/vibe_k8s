import json
from datetime import datetime

from pydantic import BaseModel


class TrackListItem(BaseModel):
    id: str
    title: str
    artist: str
    album: str
    status: str
    duration_sec: float | None
    created_at: datetime
    stream_url: str | None

    @classmethod
    def from_model(cls, t) -> "TrackListItem":
        return cls(
            id=t.id, title=t.title, artist=t.artist, album=t.album,
            status=t.status, duration_sec=t.duration_sec, created_at=t.created_at,
            stream_url=f"/stream/{t.id}/master.m3u8" if t.status == "ready" else None,
        )


class TrackOut(BaseModel):
    id: str
    title: str
    artist: str
    album: str
    status: str
    duration_sec: float | None
    waveform: list[float] | None
    error: str | None
    worker: str | None
    created_at: datetime
    stream_url: str | None

    @classmethod
    def from_model(cls, t) -> "TrackOut":
        return cls(
            id=t.id,
            title=t.title,
            artist=t.artist,
            album=t.album,
            status=t.status,
            duration_sec=t.duration_sec,
            waveform=json.loads(t.waveform) if t.waveform else None,
            error=t.error,
            worker=t.worker,
            created_at=t.created_at,
            stream_url=f"/stream/{t.id}/master.m3u8" if t.status == "ready" else None,
        )


# Nombre explícito para el endpoint de detalle; TrackOut se conserva para el API de upload.
TrackDetail = TrackOut


class Stats(BaseModel):
    pod: str
    queue_length: int
    pending: int
    processing: int
    ready: int
    failed: int
    total: int
