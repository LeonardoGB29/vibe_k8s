"""Redis job queue helpers, separate from Python's standard queue module."""

import json

import redis

import config

r = redis.Redis.from_url(config.REDIS_URL, decode_responses=True)


def enqueue(track_id: str) -> None:
    r.rpush(config.QUEUE_NAME, json.dumps({"track_id": track_id}))


def queue_length() -> int:
    try:
        return int(r.llen(config.QUEUE_NAME))
    except Exception:
        return 0


def ping() -> bool:
    return bool(r.ping())
