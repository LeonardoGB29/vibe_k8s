#!/usr/bin/env bash
# Uso: chaos/node-down.sh [nodo=vibe-worker] [segundos_apagado=180]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

NODE="${1:-vibe-worker}"
DOWN="${2:-180}"
require_cmds kubectl docker curl
require_cluster
require_positive_int segundos "$DOWN"
[[ "$NODE" =~ ^vibe-worker[0-9]*$ ]] || die "Solo se permite un worker del cluster vibe"
docker container inspect "$NODE" >/dev/null 2>&1 || die "No existe el contenedor kind $NODE"
kubectl get node "$NODE" >/dev/null 2>&1 || die "No existe el nodo $NODE"

mapfile -t ORIGINAL_PODS < <(
  kubectl -n "$NS" get pods --field-selector="spec.nodeName=$NODE" \
    -l 'app in (frontend,catalog-api,upload-api,stream-api,worker)' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)
[[ ${#ORIGINAL_PODS[@]} -gt 0 ]] || die "El nodo no aloja pods stateless de VIBE"

NODE_STARTED=0
cleanup() {
  stop_probe
  if (( NODE_STARTED == 0 )); then
    echo "[$(now)] Restaurando $NODE"
    docker start "$NODE" >/dev/null 2>&1 || true
    NODE_STARTED=1
  fi
}
trap cleanup EXIT
start_probe "node-down-$NODE" "$BASE_URL/api/stats"

echo "Pods stateless originales en $NODE: ${ORIGINAL_PODS[*]}"
echo "[$(now)] Apagando $NODE durante ${DOWN}s"
T0=$SECONDS
docker stop "$NODE" >/dev/null

DEADLINE=$((SECONDS + 90))
until [[ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" != "True" ]]; do
  (( SECONDS < DEADLINE )) || die "El nodo no pasó a NotReady en 90s"
  sleep 2
done
echo "[$(now)] Nodo NotReady tras $((SECONDS - T0)) s"

# Los deployments incluyen tolerations de 15s para mover solo los pods stateless.
for pod in "${ORIGINAL_PODS[@]}"; do
  kubectl -n "$NS" wait --for=delete "pod/$pod" --timeout=90s >/dev/null || \
    die "$pod no fue evacuado; reaplica los manifiestos con make deploy-ms"
done
kubectl -n "$NS" wait --for=condition=Available \
  deployment/frontend deployment/catalog-api deployment/upload-api deployment/stream-api deployment/worker \
  --timeout=180s >/dev/null
echo "[$(now)] Pods reprogramados fuera de $NODE:"
kubectl -n "$NS" get pods -o wide --no-headers

REMAINING=$((DOWN - (SECONDS - T0)))
(( REMAINING > 0 )) && sleep "$REMAINING"
docker start "$NODE" >/dev/null
NODE_STARTED=1
DEADLINE=$((SECONDS + 120))
until [[ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]; do
  (( SECONDS < DEADLINE )) || die "El nodo no volvió a Ready en 120s"
  sleep 2
done
stop_probe
trap - EXIT
echo "[$(now)] Nodo Ready. Evidencia: $PROBE_FILE"
