#!/usr/bin/env bash
# Ensayo AWS medido: agente sin PVC locales, siete minutos y restauración automática.
set -euo pipefail
[[ "${1:-k3s-agent-3}" == k3s-agent-3 ]] || {
  echo "Este ensayo usa k3s-agent-3; los otros agentes alojan PostgreSQL/Redis en el laboratorio." >&2
  exit 1
}
[[ "${2:-420}" == 420 ]] || {
  echo "Usa 420 segundos para observar la evicción con las tolerancias actuales." >&2
  exit 1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
python3 "$SCRIPT_DIR/../aws/demo.py" node --base "${BASE_URL:-http://localhost:30080}"
