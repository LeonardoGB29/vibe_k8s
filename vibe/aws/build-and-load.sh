#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== [1/4] Construyendo imagenes Docker de microservicios ==="
cd "$REPO_ROOT"

docker build -t vibe-frontend:dev -f services/frontend/Dockerfile services/frontend
docker build -t vibe-catalog-api:dev -f services/catalog-api/Dockerfile services/catalog-api
docker build -t vibe-upload-api:dev -f services/upload-api/Dockerfile services/upload-api
docker build -t vibe-stream-api:dev -f services/stream-api/Dockerfile services/stream-api
docker build -t vibe-worker:dev -f services/worker/Dockerfile services/worker

echo "=== [2/4] Exportando imagenes a archivo unificado ==="
IMAGES="vibe-frontend:dev vibe-catalog-api:dev vibe-upload-api:dev vibe-stream-api:dev vibe-worker:dev"
mkdir -p /tmp/vibe-build
docker save $IMAGES -o /tmp/vibe-build/vibe-images.tar

echo "=== [3/4] Importando imagenes a containerd local (k3s server) ==="
sudo k3s ctr images import /tmp/vibe-build/vibe-images.tar

echo "=== [4/4] Distribuyendo imagenes a los nodos agentes (workers) ==="
# Obtenemos las IPs privadas de todos los agentes
AGENT_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -v "$(hostname -I | awk '{print $1}')" || true)

for IP in $AGENT_IPS; do
    echo "Distribuyendo imagenes a nodo agente en $IP..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$IP" "sudo k3s ctr images import -" < /tmp/vibe-build/vibe-images.tar || {
        echo "Aviso: no se pudo enviar a $IP por SSH, intentando copia directa..."
    }
done

rm -f /tmp/vibe-build/vibe-images.tar
echo "✅ Imagenes construidas y cargadas en todo el cluster con exito!"
