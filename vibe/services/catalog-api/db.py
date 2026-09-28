import logging
import time

from sqlalchemy import create_engine, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker

import config

log = logging.getLogger("vibe.catalog.db")

engine = create_engine(config.DATABASE_URL, pool_pre_ping=True, pool_size=10, max_overflow=20)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def wait_for_db(retries: int = 30, delay: float = 2.0) -> None:
    for i in range(retries):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("DB no disponible (%s/%s): %s", i + 1, retries, exc)
            time.sleep(delay)
    raise RuntimeError("No se pudo conectar a la base de datos")


def get_session():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
