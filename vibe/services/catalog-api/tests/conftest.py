"""Configura el entorno antes de importar la aplicación: base SQLite temporal, sin Redis ni MinIO."""
import os
import sys
import tempfile
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_DIR))
_db = Path(tempfile.mkdtemp(prefix="vibe-catalog-tests-")) / "test.db"
os.environ["DATABASE_URL"] = f"sqlite:///{_db.as_posix()}"
os.environ.setdefault("REDIS_URL", "redis://127.0.0.1:1/0")  # no se usa: las llamadas a Redis fallan en silencio
