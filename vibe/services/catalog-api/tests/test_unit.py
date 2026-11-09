"""Pruebas unitarias: lógica pura, sin base de datos ni servicios externos."""
from datetime import datetime, timezone
from types import SimpleNamespace

from schemas import TrackListItem


def _track(status: str):
    return SimpleNamespace(
        id="t-1", title="Tema", artist="Artista", album="Single", status=status,
        duration_sec=12.5, created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
    )


def test_stream_url_solo_para_pistas_listas():
    assert TrackListItem.from_model(_track("ready")).stream_url == "/stream/t-1/master.m3u8"


def test_pistas_en_proceso_no_tienen_stream_url():
    for status in ("pending", "processing", "failed"):
        assert TrackListItem.from_model(_track(status)).stream_url is None
