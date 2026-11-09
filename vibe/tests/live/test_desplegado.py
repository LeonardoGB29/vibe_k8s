"""Pruebas de integración contra un entorno DESPLEGADO (caja negra, sin acceso al clúster).

Se ejecutan en el CI tras el despliegue de desarrollo. La URL se pasa en BASE_URL, por ejemplo:
    BASE_URL=http://<elb> python -m pytest tests/live -v
Si BASE_URL no está definida, las pruebas se omiten (para no romper la ejecución en local).
"""
import os

import httpx
import pytest

BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")
pytestmark = pytest.mark.skipif(not BASE_URL, reason="BASE_URL no definida: solo se ejecuta contra un entorno desplegado")
TIMEOUT = 20


@pytest.fixture(scope="module")
def http():
    with httpx.Client(base_url=BASE_URL, timeout=TIMEOUT, follow_redirects=True) as client:
        yield client


def test_frontend_responde_html(http):
    r = http.get("/")
    assert r.status_code == 200
    assert "<title>VIBE</title>" in r.text


def test_catalogo_responde_json(http):
    r = http.get("/api/tracks")
    assert r.status_code == 200
    assert isinstance(r.json(), list)


def test_estadisticas_con_datos_de_la_base(http):
    r = http.get("/api/stats")
    assert r.status_code == 200
    body = r.json()
    assert {"total", "ready"} <= body.keys()
    assert body["total"] >= body["ready"] >= 0


def test_pista_inexistente_devuelve_404(http):
    assert http.get("/api/tracks/00000000-0000-0000-0000-000000000000").status_code == 404


def test_ruta_de_streaming_invalida_rechazada(http):
    assert http.get("/stream/x/..%2Fsecreto").status_code in (400, 404)
