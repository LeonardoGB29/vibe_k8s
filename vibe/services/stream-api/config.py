import os
import platform


def env(name: str, default: str) -> str:
    return os.getenv(name, default)


MINIO_ENDPOINT = env("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = env("MINIO_ACCESS_KEY", "vibeadmin")
MINIO_SECRET_KEY = env("MINIO_SECRET_KEY", "vibesecret123")
MINIO_SESSION_TOKEN = env("MINIO_SESSION_TOKEN", "") or None
MINIO_SECURE = env("MINIO_SECURE", "false").lower() == "true"
AWS_REGION = env("AWS_REGION", "us-east-1")

BUCKET_HLS = env("BUCKET_HLS", "hls")

try:
    _node = os.uname().nodename
except AttributeError:
    _node = platform.node()
POD_NAME = env("POD_NAME", _node)
