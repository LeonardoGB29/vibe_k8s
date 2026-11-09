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


def test_storage_usa_el_rol_de_la_instancia_en_aws(monkeypatch):
    """Con MINIO_AUTH=instance-role el cliente S3 usa el proveedor de credenciales temporales y NO claves fijas."""
    import importlib

    import config
    import minio.credentials as mc
    import storage

    sentinel = object()
    monkeypatch.setattr(config, "MINIO_AUTH", "instance-role")
    monkeypatch.setattr(mc, "IamAwsProvider", lambda: sentinel)
    try:
        importlib.reload(storage)
        assert storage._client_kwargs["credentials"] is sentinel
        assert "access_key" not in storage._client_kwargs and "secret_key" not in storage._client_kwargs
    finally:
        monkeypatch.undo()
        importlib.reload(storage)  # vuelve al modo por defecto (claves estaticas) para el resto de pruebas


def test_storage_usa_claves_estaticas_por_defecto():
    import storage

    assert "credentials" not in storage._client_kwargs
    assert "access_key" in storage._client_kwargs
