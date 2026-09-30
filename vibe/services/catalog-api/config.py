import os
import platform


def env(name: str, default: str) -> str:
    return os.getenv(name, default)


DATABASE_URL = env("DATABASE_URL", "postgresql+psycopg://vibe:vibe@localhost:5432/vibe")
REDIS_URL = env("REDIS_URL", "redis://localhost:6379/0")

MINIO_ENDPOINT = env("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = env("MINIO_ACCESS_KEY", "vibeadmin")
MINIO_SECRET_KEY = env("MINIO_SECRET_KEY", "vibesecret123")
MINIO_SESSION_TOKEN = env("MINIO_SESSION_TOKEN", "") or None
MINIO_SECURE = env("MINIO_SECURE", "false").lower() == "true"
AWS_REGION = env("AWS_REGION", "us-east-1")

BUCKET_RAW = env("BUCKET_RAW", "raw")
BUCKET_HLS = env("BUCKET_HLS", "hls")
QUEUE_NAME = env("QUEUE_NAME", "transcode")

try:
    _node = os.uname().nodename
except AttributeError:
    _node = platform.node()
POD_NAME = env("POD_NAME", _node)
MAX_UPLOAD_MB = int(env("MAX_UPLOAD_MB", "200"))
DB_POOL_SIZE = int(env("DB_POOL_SIZE", "5"))
DB_MAX_OVERFLOW = int(env("DB_MAX_OVERFLOW", "5"))
DB_POOL_TIMEOUT = float(env("DB_POOL_TIMEOUT", "5"))
DB_POOL_RECYCLE = int(env("DB_POOL_RECYCLE", "1800"))
CATALOG_CACHE_TTL = int(env("CATALOG_CACHE_TTL", "4"))
