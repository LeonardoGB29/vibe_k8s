import logging

from minio import Minio
from minio.error import S3Error

import config

log = logging.getLogger("vibe.catalog.storage")

_client_kwargs = {
    "endpoint": config.MINIO_ENDPOINT,
    "access_key": config.MINIO_ACCESS_KEY,
    "secret_key": config.MINIO_SECRET_KEY,
    "secure": config.MINIO_SECURE,
}
if config.MINIO_SESSION_TOKEN:
    _client_kwargs["session_token"] = config.MINIO_SESSION_TOKEN
if config.AWS_REGION:
    _client_kwargs["region"] = config.AWS_REGION

client = Minio(**_client_kwargs)


def delete_prefix(bucket: str, prefix: str) -> None:
    try:
        for obj in client.list_objects(bucket, prefix=prefix, recursive=True):
            client.remove_object(bucket, obj.object_name)
    except Exception as exc:
        log.warning("Error eliminando prefijo %s en %s: %s", prefix, bucket, exc)


def delete_key(bucket: str, key: str) -> None:
    try:
        client.remove_object(bucket, key)
    except S3Error:
        pass
    except Exception as exc:
        log.warning("Error eliminando key %s en %s: %s", key, bucket, exc)
