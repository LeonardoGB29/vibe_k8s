#!/usr/bin/env bash
# Borra el pod de Postgres y verifica que el StatefulSet lo recrea con el mismo PVC
# y que los datos siguen ahí.
set -euo pipefail
NS=vibe

BEFORE=$(curl -s localhost/api/stats | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
echo "[$(date +%T)] Tracks antes: $BEFORE"
echo "[$(date +%T)] Borrando postgres-0"
T0=$(date +%s)
kubectl -n $NS delete pod postgres-0 --wait=false

# cuenta errores de la API mientras la BD no está
ERR=0; OK=0
until [[ "$(kubectl -n $NS get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" == "true" ]]; do
  if curl -sf -o /dev/null localhost/api/stats; then OK=$((OK+1)); else ERR=$((ERR+1)); fi
  sleep 0.5
done
echo "[$(date +%T)] Postgres de vuelta en $(( $(date +%s) - T0 )) s (requests durante la caída: $OK ok, $ERR error)"

sleep 3
AFTER=$(curl -s localhost/api/stats | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
echo "[$(date +%T)] Tracks después: $AFTER"
[[ "$BEFORE" == "$AFTER" ]] && echo "OK: los datos sobrevivieron (PVC)" || echo "ATENCIÓN: se perdieron datos"
