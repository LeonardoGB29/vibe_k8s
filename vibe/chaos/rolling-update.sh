#!/usr/bin/env bash
# Construye y prueba una imagen de frontend distinta, luego restaura la original.
# En AWS requiere Docker, S3, SSM y las imágenes :dev ya cargadas en los agentes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
python3 "$SCRIPT_DIR/../aws/demo.py" rolling --base "${BASE_URL:-http://localhost:30080}"
