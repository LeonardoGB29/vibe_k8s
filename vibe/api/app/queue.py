import json

import redis

from . import config

r = redis.Redis.from_url(config.REDIS_URL, decode_responses=True)


def enqueue(track_id: str) -> None:
    r.rpush(config.QUEUE_NAME, json.dumps({"track_id": track_id}))


def queue_length() -> int:
    return int(r.llen(config.QUEUE_NAME))


def ping() -> bool:
    return bool(r.ping())
