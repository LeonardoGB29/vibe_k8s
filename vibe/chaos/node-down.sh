#!/usr/bin/env bash
# Uso: chaos/node-down.sh [nodo=vibe-worker] [segundos_apagado=180]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

NODE="${1:-vibe-worker}"
DOWN="${2:-180}"
require_cmds kubectl docker curl python3
require_cluster
require_positive_int segundos "$DOWN"
[[ "$NODE" =~ ^vibe-worker[0-9]*$ ]] || die "Solo se permite un worker del cluster vibe"
docker container inspect "$NODE" >/dev/null 2>&1 || die "No existe el contenedor kind $NODE"
kubectl get node "$NODE" >/dev/null 2>&1 || die "No existe el nodo $NODE"

mapfile -t ORIGINAL_ROWS < <(
  kubectl -n "$NS" get pods --field-selector="spec.nodeName=$NODE" \
    -l 'app in (frontend,catalog-api,upload-api,stream-api,worker)' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.app}{"\n"}{end}'
)
[[ ${#ORIGINAL_ROWS[@]} -gt 0 ]] || die "El nodo no aloja pods stateless de VIBE"

declare -a ORIGINAL_PODS=()
declare -a AFFECTED_APPS=()
declare -A APP_SEEN=()
declare -A APP_BASELINE=()
for row in "${ORIGINAL_ROWS[@]}"; do
  pod="${row%%|*}"
  app="${row#*|}"
  ORIGINAL_PODS+=("$pod")
  if [[ -z "${APP_SEEN[$app]:-}" ]]; then
    APP_SEEN[$app]=1
    AFFECTED_APPS+=("$app")
    APP_BASELINE[$app]="$(
      kubectl -n "$NS" get pods -l "app=$app" \
        -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}'
    )"
  fi
done

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
# Un pod del nodo inaccesible puede quedar en Terminating hasta que vuelva el
# kubelet. La evacuación se considera correcta cuando aparece un reemplazo
# nuevo asignado a otro nodo; no cuando desaparece el objeto antiguo.
# Su fase y estado Ready se informan aparte: puede depender de PostgreSQL, MinIO o
# Redis, que no se pueden reprogramar mientras su volumen local está apagado.
for app in "${AFFECTED_APPS[@]}"; do
  baseline="${APP_BASELINE[$app]}"
  deadline=$((SECONDS + 180))
  replacement=""
  while (( SECONDS < deadline )); do
    replacement="$(
      kubectl -n "$NS" get pods -l "app=$app" -o json 2>/dev/null | \
        python3 -c '
import json
import sys

target = sys.argv[1]
baseline = {name for name in sys.argv[2].split(",") if name}
for pod in json.load(sys.stdin).get("items", []):
    meta = pod.get("metadata", {})
    spec = pod.get("spec", {})
    status = pod.get("status", {})
    ready = any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in status.get("conditions", [])
    )
    name = meta.get("name", "")
    node = spec.get("nodeName", "")
    if (
        name not in baseline
        and node
        and node != target
        and not meta.get("deletionTimestamp")
    ):
        readiness = "Ready" if ready else "NotReady"
        phase = status.get("phase", "Unknown")
        print(f"{name}@{node}|{phase}/{readiness}")
        break
' "$NODE" "$baseline" || true
    )"
    [[ -n "$replacement" ]] && break
    sleep 2
  done
  [[ -n "$replacement" ]] || \
    die "No apareció un reemplazo de $app asignado fuera de $NODE en 180s"
  replacement_pod="${replacement%%|*}"
  replacement_state="${replacement#*|}"
  echo "[$(now)] $app reprogramado: $replacement_pod ($replacement_state)"
  if [[ "$replacement_state" != "Running/Ready" ]]; then
    echo "[$(now)] AVISO: $app depende de un servicio con estado del nodo caído; se verificará de nuevo tras restaurarlo"
  fi
done
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
echo "[$(now)] Nodo Ready; esperando recuperación completa de los servicios"
kubectl -n "$NS" wait --for=condition=Available \
  deployment/frontend deployment/catalog-api deployment/upload-api deployment/stream-api deployment/worker deployment/redis \
  --timeout=180s >/dev/null
kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s >/dev/null
kubectl -n "$NS" rollout status statefulset/minio --timeout=180s >/dev/null
stop_probe
trap - EXIT
echo "[$(now)] Nodo Ready. Evidencia: $PROBE_FILE"
