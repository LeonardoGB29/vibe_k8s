import logging

from minio import Minio
from minio.error import S3Error

import config

log = logging.getLogger("vibe.stream.storage")

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


def get_object(bucket: str, key: str):
    """Devuelve la respuesta urllib3 de MinIO (stream) o None si no existe."""
    try:
        return client.get_object(bucket, key)
    except S3Error as exc:
        if exc.code in ("NoSuchKey", "NoSuchObject", "NoSuchBucket"):
            return None
        raise
