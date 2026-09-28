import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from db import Base


def now() -> datetime:
    return datetime.now(timezone.utc)


class Track(Base):
    __tablename__ = "tracks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    artist: Mapped[str] = mapped_column(String(200), nullable=False, default="Desconocido")
    album: Mapped[str] = mapped_column(String(200), nullable=False, default="Single")
    # pending -> processing -> ready | failed
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="pending", index=True)
    duration_sec: Mapped[float | None] = mapped_column(Float, nullable=True)
    raw_key: Mapped[str] = mapped_column(String(300), nullable=False)
    hls_prefix: Mapped[str | None] = mapped_column(String(300), nullable=True)
    waveform: Mapped[str | None] = mapped_column(Text, nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    worker: Mapped[str | None] = mapped_column(String(120), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, onupdate=now, nullable=False)

    __table_args__ = (Index("ix_tracks_created", "created_at"),)
