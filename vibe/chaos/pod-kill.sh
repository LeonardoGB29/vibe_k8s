#!/usr/bin/env bash
# Uso: chaos/pod-kill.sh [intervalo_seg=15] [veces=1] [app=catalog-api]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INTERVAL="${1:-15}"
TIMES="${2:-1}"
APP="${3:-catalog-api}"
require_cmds kubectl curl
require_cluster
require_positive_int intervalo "$INTERVAL"
require_positive_int veces "$TIMES"
[[ "$APP" =~ ^[a-z0-9-]+$ ]] || die "Nombre de app inválido"
kubectl -n "$NS" get deployment "$APP" >/dev/null 2>&1 || die "No existe deployment/$APP"

trap 'stop_probe' EXIT
start_probe "pod-kill-$APP" "$BASE_URL/api/stats"

for ((i=1; i<=TIMES; i++)); do
  POD="$(kubectl -n "$NS" get pods -l "app=$APP" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$POD" ]] || die "No hay pod Running para app=$APP"
  echo "[$(now)] ($i/$TIMES) Eliminando $POD"
  T0=$SECONDS
  kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
  kubectl -n "$NS" wait --for=delete "pod/$POD" --timeout=120s >/dev/null
  kubectl -n "$NS" rollout status "deployment/$APP" --timeout=120s >/dev/null
  echo "[$(now)] Recuperado en $((SECONDS - T0)) s"
  kubectl -n "$NS" get pods -l "app=$APP" -o wide --no-headers
  (( i < TIMES )) && sleep "$INTERVAL"
done

stop_probe
trap - EXIT
echo "Evidencia: $PROBE_FILE"
