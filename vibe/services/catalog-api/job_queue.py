"""Redis job queue helpers, separate from Python's standard queue module."""

import redis

import config

r = redis.Redis.from_url(config.REDIS_URL, decode_responses=True, socket_connect_timeout=0.5, socket_timeout=0.5)


def queue_length() -> int:
    try:
        return int(r.llen(config.QUEUE_NAME))
    except Exception:
        return 0


def ping() -> bool:
    return bool(r.ping())


def invalidate_catalog() -> None:
    """Advance the shared cache generation; cache failures never block writes."""
    try:
        r.incr("vibe:catalog:version")
    except Exception:
        pass
