import logging
import time

from minio import Minio
from minio.error import S3Error

from . import config

log = logging.getLogger("vibe.storage")

client = Minio(
    config.MINIO_ENDPOINT,
    access_key=config.MINIO_ACCESS_KEY,
    secret_key=config.MINIO_SECRET_KEY,
    secure=config.MINIO_SECURE,
)


def ensure_buckets(retries: int = 30, delay: float = 2.0) -> None:
    for i in range(retries):
        try:
            for bucket in (config.BUCKET_RAW, config.BUCKET_HLS):
                if not client.bucket_exists(bucket):
                    client.make_bucket(bucket)
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("MinIO no disponible (%s/%s): %s", i + 1, retries, exc)
            time.sleep(delay)
    raise RuntimeError("No se pudo conectar a MinIO")


def put_file(bucket: str, key: str, path: str, content_type: str) -> None:
    client.fput_object(bucket, key, path, content_type=content_type)


def get_object(bucket: str, key: str):
    """Devuelve la respuesta urllib3 de MinIO (stream) o None si no existe."""
    try:
        return client.get_object(bucket, key)
    except S3Error as exc:
        if exc.code in ("NoSuchKey", "NoSuchObject"):
            return None
        raise


def delete_prefix(bucket: str, prefix: str) -> None:
    for obj in client.list_objects(bucket, prefix=prefix, recursive=True):
        client.remove_object(bucket, obj.object_name)


def delete_key(bucket: str, key: str) -> None:
    try:
        client.remove_object(bucket, key)
    except S3Error:
        pass
