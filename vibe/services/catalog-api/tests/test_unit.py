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
    import instance_credentials
    import storage

    sentinel = object()
    monkeypatch.setattr(config, "MINIO_AUTH", "instance-role")
    monkeypatch.setattr(instance_credentials, "InstanceRoleProvider", lambda: sentinel)
    try:
        importlib.reload(storage)
        assert storage._client_kwargs["credentials"] is sentinel
        assert "access_key" not in storage._client_kwargs and "secret_key" not in storage._client_kwargs
    finally:
        monkeypatch.undo()
        importlib.reload(storage)  # vuelve al modo por defecto (claves estaticas) para el resto de pruebas


def _imds(monkeypatch, expirations):
    """Simula el servicio de metadatos IMDSv2; cada llamada a credenciales usa la siguiente caducidad."""
    import io
    import json
    import urllib.request

    llamadas = []

    class Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fake_urlopen(request, timeout=None):
        ruta, metodo = request.full_url.split("169.254.169.254")[1], request.get_method()
        llamadas.append((metodo, ruta, request.get_header("X-aws-ec2-metadata-token")))
        if ruta == "/latest/api/token":
            return Resp(b"TOKEN-IMDS")
        if ruta == "/latest/meta-data/iam/security-credentials/":
            return Resp(b"mi-rol\n")
        if ruta == "/latest/meta-data/iam/security-credentials/mi-rol":
            n = sum(1 for m, r, _ in llamadas if r.endswith("/mi-rol"))
            return Resp(json.dumps({
                "Code": "Success", "AccessKeyId": f"ASIA{n}", "SecretAccessKey": "secreto",
                "Token": f"token{n}", "Expiration": expirations[min(n, len(expirations)) - 1],
            }).encode())
        raise AssertionError(f"ruta inesperada {ruta}")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    return llamadas


def test_proveedor_del_rol_sigue_el_protocolo_imdsv2(monkeypatch):
    from datetime import datetime, timedelta, timezone

    import instance_credentials as ic

    futuro = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    llamadas = _imds(monkeypatch, [futuro])
    provider = ic.InstanceRoleProvider()

    creds = provider.retrieve()
    assert (creds.access_key, creds.session_token) == ("ASIA1", "token1")
    # token IMDSv2 primero (PUT) y despues las dos lecturas llevan ese token y la ruta COMPLETA de credenciales
    assert [(m, r) for m, r, _ in llamadas] == [
        ("PUT", "/latest/api/token"),
        ("GET", "/latest/meta-data/iam/security-credentials/"),
        ("GET", "/latest/meta-data/iam/security-credentials/mi-rol"),
    ]
    assert all(t == "TOKEN-IMDS" for m, _, t in llamadas if m == "GET")

    provider.retrieve()  # siguen vigentes: no vuelve a llamar a IMDS
    assert len(llamadas) == 3


def test_proveedor_renueva_cuando_las_credenciales_caducan(monkeypatch):
    from datetime import datetime, timedelta, timezone

    import instance_credentials as ic

    pasado = (datetime.now(timezone.utc) - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    futuro = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    _imds(monkeypatch, [pasado, futuro])
    provider = ic.InstanceRoleProvider()

    assert provider.retrieve().access_key == "ASIA1"   # ya caducadas al recibirlas
    assert provider.retrieve().access_key == "ASIA2"   # se piden otras nuevas
    assert provider.retrieve().access_key == "ASIA2"   # estas siguen vigentes


def test_storage_usa_claves_estaticas_por_defecto():
    import storage

    assert "credentials" not in storage._client_kwargs
    assert "access_key" in storage._client_kwargs
