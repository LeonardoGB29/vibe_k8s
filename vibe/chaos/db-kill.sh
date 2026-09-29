#!/usr/bin/env bash
# Reinicia PostgreSQL y verifica pod, PVC y cantidad de tracks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_cmds kubectl curl python3
require_cluster

json_total() { python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'; }
BEFORE="$(curl -fsS --max-time 10 "$BASE_URL/api/stats" | json_total)"
PVC_BEFORE="$(kubectl -n "$NS" get pod postgres-0 -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')"
UID_BEFORE="$(kubectl -n "$NS" get pod postgres-0 -o jsonpath='{.metadata.uid}')"
[[ -n "$PVC_BEFORE" ]] || die "postgres-0 no tiene PVC"

trap 'stop_probe' EXIT
start_probe db-kill "$BASE_URL/api/stats"
echo "[$(now)] Tracks antes: $BEFORE; PVC: $PVC_BEFORE"
T0=$SECONDS
kubectl -n "$NS" delete pod postgres-0 --wait=false >/dev/null
DEADLINE=$((SECONDS + 180))
while true; do
  UID_NOW="$(kubectl -n "$NS" get pod postgres-0 -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  READY_NOW="$(kubectl -n "$NS" get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  [[ -n "$UID_NOW" && "$UID_NOW" != "$UID_BEFORE" && "$READY_NOW" == "true" ]] && break
  (( SECONDS < DEADLINE )) || die "PostgreSQL no se recuperó en 180s"
  sleep 1
done
sleep 3
echo "[$(now)] PostgreSQL recuperado en $((SECONDS - T0)) s"

AFTER="$(curl -fsS --retry 10 --retry-delay 1 --max-time 10 "$BASE_URL/api/stats" | json_total)"
PVC_AFTER="$(kubectl -n "$NS" get pod postgres-0 -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')"
stop_probe
trap - EXIT

echo "[$(now)] Tracks después: $AFTER; PVC: $PVC_AFTER"
[[ "$BEFORE" == "$AFTER" ]] || die "Cambió el total de tracks: $BEFORE -> $AFTER"
[[ "$PVC_BEFORE" == "$PVC_AFTER" ]] || die "Cambió el PVC: $PVC_BEFORE -> $PVC_AFTER"
echo "OK: datos y PVC se conservaron. Evidencia: $PROBE_FILE"
