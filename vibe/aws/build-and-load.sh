#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_USER="${SSH_USER:-ec2-user}"
IMAGE_DISTRIBUTION="${IMAGE_DISTRIBUTION:-ssh}"
if [[ "$IMAGE_DISTRIBUTION" == ssh ]]; then
    SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:?Indica SSH_PRIVATE_KEY con la ruta a labsuser.pem en el servidor}"
    [[ -r "$SSH_PRIVATE_KEY" ]] || { echo "No se puede leer la clave SSH indicada" >&2; exit 1; }
    SSH_ARGS=(-i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
elif [[ "$IMAGE_DISTRIBUTION" == ssm ]]; then
    : "${IMAGE_BUCKET:?Indica IMAGE_BUCKET para distribuir las imágenes mediante S3}"
    aws sts get-caller-identity >/dev/null
else
    echo "IMAGE_DISTRIBUTION debe ser ssh o ssm" >&2
    exit 1
fi
AGENT_IPS=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.name != "k3s-server") | .status.addresses[] | select(.type == "InternalIP") | .address')
[[ "$(printf '%s\n' "$AGENT_IPS" | sed '/^$/d' | wc -l | tr -d ' ')" == 3 ]] || {
    echo "Se esperaban exactamente tres agentes; revisa kubectl get nodes" >&2
    exit 1
}
if [[ "$IMAGE_DISTRIBUTION" == ssh ]]; then
    for IP in $AGENT_IPS; do
        ssh "${SSH_ARGS[@]}" "$SSH_USER@$IP" "sudo k3s ctr images ls -q >/dev/null"
    done
else
    bash "$SCRIPT_DIR/distribute-ssm.sh" --check
fi

echo "=== [1/4] Construyendo imagenes Docker de microservicios ==="
cd "$REPO_ROOT"

docker build -t vibe-frontend:dev -f services/frontend/Dockerfile services/frontend
docker build -t vibe-catalog-api:dev -f services/catalog-api/Dockerfile services/catalog-api
docker build -t vibe-upload-api:dev -f services/upload-api/Dockerfile services/upload-api
docker build -t vibe-stream-api:dev -f services/stream-api/Dockerfile services/stream-api
docker build -t vibe-worker:dev -f services/worker/Dockerfile services/worker

echo "=== [2/4] Exportando imagenes a archivo unificado ==="
IMAGES="vibe-frontend:dev vibe-catalog-api:dev vibe-upload-api:dev vibe-stream-api:dev vibe-worker:dev"
BUILD_DIR=$(mktemp -d /tmp/vibe-build.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
docker save $IMAGES -o "$BUILD_DIR/vibe-images.tar"

echo "=== [3/4] Importando imagenes a containerd local (k3s server) ==="
sudo k3s ctr images import "$BUILD_DIR/vibe-images.tar"

echo "=== [4/4] Distribuyendo imagenes a los nodos agentes (workers) ==="
if [[ "$IMAGE_DISTRIBUTION" == ssm ]]; then
    bash "$SCRIPT_DIR/distribute-ssm.sh" "$BUILD_DIR/vibe-images.tar"
    echo "✅ Imágenes importadas mediante S3 y SSM en los tres agentes"
    exit 0
fi
for IP in $AGENT_IPS; do
    echo "Distribuyendo imagenes a nodo agente en $IP..."
    ssh "${SSH_ARGS[@]}" "$SSH_USER@$IP" "sudo k3s ctr images import -" < "$BUILD_DIR/vibe-images.tar"
    for IMAGE in $IMAGES; do
        ssh "${SSH_ARGS[@]}" "$SSH_USER@$IP" "sudo k3s ctr images ls -q" | grep -Fx "docker.io/library/$IMAGE" >/dev/null
    done
done

echo "✅ Imagenes construidas y cargadas en todo el cluster con exito!"
