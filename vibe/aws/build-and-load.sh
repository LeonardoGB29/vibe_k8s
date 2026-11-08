#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Las imagenes se distribuyen a los agentes mediante S3 y SSM Run Command.
: "${IMAGE_BUCKET:?Indica IMAGE_BUCKET para distribuir las imágenes mediante S3}"
aws sts get-caller-identity >/dev/null
AGENT_IPS=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.name != "k3s-server") | .status.addresses[] | select(.type == "InternalIP") | .address')
[[ "$(printf '%s\n' "$AGENT_IPS" | sed '/^$/d' | wc -l | tr -d ' ')" == 3 ]] || {
    echo "Se esperaban exactamente tres agentes; revisa kubectl get nodes" >&2
    exit 1
}
bash "$SCRIPT_DIR/distribute-ssm.sh" --check

echo "=== [1/4] Construyendo imagenes Docker de microservicios ==="
cd "$REPO_ROOT"

require_free_mib() {
    local minimum_mib="$1" phase="$2" available_mib
    available_mib="$(df -Pm / | awk 'NR == 2 {print $4}')"
    echo "Espacio libre en k3s-server ${phase}: ${available_mib} MiB"
    if (( available_mib < minimum_mib )); then
        echo "Espacio insuficiente en k3s-server ${phase}: se requieren ${minimum_mib} MiB libres. Libera espacio y vuelve a desplegar." >&2
        exit 1
    fi
}

require_free_mib "${VIBE_MIN_BUILD_REMAINING_MIB:-1500}" "antes de construir"
docker build -t vibe-frontend:dev -f services/frontend/Dockerfile services/frontend
require_free_mib "${VIBE_MIN_BUILD_REMAINING_MIB:-1500}" "después de frontend"
docker build -t vibe-catalog-api:dev -f services/catalog-api/Dockerfile services/catalog-api
require_free_mib "${VIBE_MIN_BUILD_REMAINING_MIB:-1500}" "después de catalog-api"
docker build -t vibe-upload-api:dev -f services/upload-api/Dockerfile services/upload-api
require_free_mib "${VIBE_MIN_BUILD_REMAINING_MIB:-1500}" "después de upload-api"
docker build -t vibe-stream-api:dev -f services/stream-api/Dockerfile services/stream-api
require_free_mib "${VIBE_MIN_BUILD_REMAINING_MIB:-1500}" "después de stream-api"
docker build -t vibe-worker:dev -f services/worker/Dockerfile services/worker
require_free_mib "${VIBE_MIN_EXPORT_REMAINING_MIB:-4000}" "antes de exportar imágenes"

echo "=== [2/4] Exportando imagenes a archivo unificado ==="
IMAGES="vibe-frontend:dev vibe-catalog-api:dev vibe-upload-api:dev vibe-stream-api:dev vibe-worker:dev"
BUILD_DIR=$(mktemp -d /tmp/vibe-build.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
docker save $IMAGES -o "$BUILD_DIR/vibe-images.tar"

echo "=== [3/4] Importando imagenes a containerd local (k3s server) ==="
sudo k3s ctr images import "$BUILD_DIR/vibe-images.tar"

echo "=== [4/4] Distribuyendo imagenes a los nodos agentes (workers) ==="
bash "$SCRIPT_DIR/distribute-ssm.sh" "$BUILD_DIR/vibe-images.tar"
echo "✅ Imágenes construidas y cargadas en todo el cluster mediante S3 y SSM"
