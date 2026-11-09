import logging
import time

from minio import Minio
from minio.error import S3Error

import config

log = logging.getLogger("vibe.upload.storage")

_client_kwargs = {
    "endpoint": config.MINIO_ENDPOINT,
    "secure": config.MINIO_SECURE,
}
if config.MINIO_AUTH == "instance-role":
    # AWS: credenciales temporales del rol de la EC2 (IMDSv2). El cliente las renueva solo antes de
    # que caduquen, asi que no hay claves ni tokens copiados a ningun Secret.
    from instance_credentials import InstanceRoleProvider

    _client_kwargs["credentials"] = InstanceRoleProvider()
else:
    # Local (kind/docker compose) con MinIO: claves estaticas.
    _client_kwargs["access_key"] = config.MINIO_ACCESS_KEY
    _client_kwargs["secret_key"] = config.MINIO_SECRET_KEY
    if config.MINIO_SESSION_TOKEN:
        _client_kwargs["session_token"] = config.MINIO_SESSION_TOKEN
if config.AWS_REGION:
    _client_kwargs["region"] = config.AWS_REGION

client = Minio(**_client_kwargs)


def ensure_buckets(retries: int = 30, delay: float = 2.0) -> None:
    for i in range(retries):
        try:
            for bucket in (config.BUCKET_RAW, config.BUCKET_HLS):
                if not client.bucket_exists(bucket):
                    try:
                        client.make_bucket(bucket)
                    except S3Error as err:
                        if err.code in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
                            pass
                        else:
                            raise
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("Storage no disponible (%s/%s): %s", i + 1, retries, exc)
            time.sleep(delay)
    raise RuntimeError("No se pudo conectar al storage (MinIO/S3)")


def put_file(bucket: str, key: str, path: str, content_type: str) -> None:
    client.fput_object(bucket, key, path, content_type=content_type)
