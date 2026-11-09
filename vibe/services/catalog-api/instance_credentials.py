"""Credenciales temporales del rol de la instancia EC2 (IMDSv2) para el cliente S3 de MinIO.

Se usa en lugar de minio.credentials.IamAwsProvider, que en minio 7.2.9 construye mal la URL de las
credenciales (pide http://169.254.169.254/<rol> en vez de .../latest/meta-data/iam/security-credentials/<rol>)
y falla con 404. Las credenciales se renuevan solas antes de caducar.
"""
import json
import threading
import urllib.request

from minio.credentials import Credentials, Provider
from minio.time import from_iso8601utc

IMDS = "http://169.254.169.254"
CREDENTIALS_PATH = "/latest/meta-data/iam/security-credentials/"


class InstanceRoleProvider(Provider):
    def __init__(self, base_url: str = IMDS, timeout: float = 3.0):
        self._base = base_url.rstrip("/")
        self._timeout = timeout
        self._credentials: Credentials | None = None
        self._lock = threading.Lock()

    def _request(self, method: str, path: str, headers: dict | None = None) -> str:
        request = urllib.request.Request(self._base + path, method=method, headers=headers or {})
        with urllib.request.urlopen(request, timeout=self._timeout) as response:  # noqa: S310 (URL fija de IMDS)
            return response.read().decode("utf-8")

    def retrieve(self) -> Credentials:
        with self._lock:
            if self._credentials and not self._credentials.is_expired():
                return self._credentials
            token = self._request("PUT", "/latest/api/token", {"X-aws-ec2-metadata-token-ttl-seconds": "300"})
            headers = {"X-aws-ec2-metadata-token": token}
            role = self._request("GET", CREDENTIALS_PATH, headers).split()[0]
            data = json.loads(self._request("GET", CREDENTIALS_PATH + role, headers))
            if data.get("Code", "Success") != "Success":
                raise ValueError(f"IMDS devolvio {data.get('Code')}: {data.get('Message')}")
            self._credentials = Credentials(
                data["AccessKeyId"], data["SecretAccessKey"], data["Token"], from_iso8601utc(data["Expiration"]),
            )
            return self._credentials
