import os


def env(name: str, default: str) -> str:
    return os.getenv(name, default)


DATABASE_URL = env("DATABASE_URL", "postgresql+psycopg://vibe:vibe@localhost:5432/vibe")
REDIS_URL = env("REDIS_URL", "redis://localhost:6379/0")

MINIO_ENDPOINT = env("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = env("MINIO_ACCESS_KEY", "vibeadmin")
MINIO_SECRET_KEY = env("MINIO_SECRET_KEY", "vibesecret123")
MINIO_SECURE = env("MINIO_SECURE", "false").lower() == "true"

BUCKET_RAW = env("BUCKET_RAW", "raw")
BUCKET_HLS = env("BUCKET_HLS", "hls")
QUEUE_NAME = env("QUEUE_NAME", "transcode")

POD_NAME = env("POD_NAME", os.uname().nodename)
MAX_UPLOAD_MB = int(env("MAX_UPLOAD_MB", "200"))
