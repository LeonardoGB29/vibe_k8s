"""Pruebas de integración: la API completa contra una base de datos real (SQLite temporal)."""
import uuid
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

import main
from db import SessionLocal
from models import Track


@pytest.fixture(scope="module")
def client():
    with TestClient(main.app) as c:  # ejecuta el lifespan: espera la base y crea las tablas
        yield c


@pytest.fixture()
def track_id():
    tid = str(uuid.uuid4())
    with SessionLocal() as db:
        db.add(Track(id=tid, title="Listo", artist="A", album="B", status="ready",
                     duration_sec=30.0, raw_key="raw/x.mp3", hls_prefix=f"tracks/{tid}/",
                     created_at=datetime.now(timezone.utc)))
        db.add(Track(id=str(uuid.uuid4()), title="Pendiente", artist="A", album="B",
                     status="pending", raw_key="raw/y.mp3", created_at=datetime.now(timezone.utc)))
        db.commit()
    return tid


def test_healthz(client):
    assert client.get("/healthz").status_code == 200


def test_lista_de_pistas_incluye_las_creadas(client, track_id):
    r = client.get("/api/tracks")
    assert r.status_code == 200
    titulos = {t["title"] for t in r.json()}
    assert {"Listo", "Pendiente"} <= titulos


def test_detalle_de_pista_existente(client, track_id):
    r = client.get(f"/api/tracks/{track_id}")
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == track_id and body["stream_url"] == f"/stream/{track_id}/master.m3u8"


def test_pista_inexistente_devuelve_404(client):
    assert client.get(f"/api/tracks/{uuid.uuid4()}").status_code == 404


def test_estadisticas(client, track_id):
    r = client.get("/api/stats")
    assert r.status_code == 200
    assert r.json()["total"] >= 2
