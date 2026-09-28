import redis

import config

r = redis.Redis.from_url(config.REDIS_URL, decode_responses=True)


def queue_length() -> int:
    try:
        return int(r.llen(config.QUEUE_NAME))
    except Exception:
        return 0


def ping() -> bool:
    return bool(r.ping())
