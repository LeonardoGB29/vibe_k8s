"""Pruebas de integración de stream-api: la validación de rutas y la entrega de segmentos.
El almacenamiento (MinIO/S3) se sustituye por un doble: no hace falta un bucket real para probar la lógica."""
import io

import pytest
from fastapi.testclient import TestClient

import main
import storage


class FakeObject:
    def __init__(self, data: bytes):
        self._buf = io.BytesIO(data)

    def release_conn(self):
        pass

    def close(self):
        self._buf.close()

    def stream(self, size):
        while chunk := self._buf.read(size):
            yield chunk


@pytest.fixture()
def client(monkeypatch):
    objects = {"tracks/t1/master.m3u8": b"#EXTM3U\n", "tracks/t1/seg_0.ts": b"\x47" * 188}
    monkeypatch.setattr(storage, "get_object", lambda bucket, key: FakeObject(objects[key]) if key in objects else None)
    return TestClient(main.app)


def test_sirve_playlist_con_tipo_correcto(client):
    r = client.get("/stream/t1/master.m3u8")
    assert r.status_code == 200
    assert r.content == b"#EXTM3U\n"
    assert "mpegurl" in r.headers["content-type"] or "m3u8" in r.headers["content-type"]


def test_sirve_segmentos_ts(client):
    r = client.get("/stream/t1/seg_0.ts")
    assert r.status_code == 200 and len(r.content) == 188


def test_segmento_inexistente_404(client):
    assert client.get("/stream/t1/no-existe.ts").status_code == 404


@pytest.mark.parametrize("path", ["..%2Fsecreto", "%2Fetc%2Fpasswd"])
def test_rutas_con_traversal_rechazadas(client, path):
    assert client.get(f"/stream/t1/{path}").status_code in (400, 404)
