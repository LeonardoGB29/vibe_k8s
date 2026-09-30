#!/usr/bin/env bash
# Uso: chaos/oom.sh | chaos/oom.sh restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_cmds kubectl python3
require_cluster

if [[ "${1:-}" == "restore" ]]; then
  RESTORE_PATCH='{"spec":{"template":{"spec":{"containers":[{"name":"worker","command":null,"args":null,"resources":{"requests":{"cpu":"100m","memory":"96Mi"},"limits":{"cpu":"1","memory":"512Mi"}}}]}}}}'
  kubectl -n "$NS" patch deployment worker --type=strategic -p "$RESTORE_PATCH" >/dev/null
  kubectl -n "$NS" rollout status deployment/worker --timeout=180s
  echo "Recursos restaurados: request 96Mi, límite 512Mi"
  exit 0
fi
[[ $# -eq 0 ]] || die "Uso: chaos/oom.sh [restore]"

OOM_PATCH='{"spec":{"template":{"spec":{"containers":[{"name":"worker","command":["python3","-c","import time\nblocks = []\nwhile True:\n    blocks.append(bytearray(8 * 1024 * 1024))\n    time.sleep(0.05)"],"args":null,"resources":{"requests":{"cpu":"50m","memory":"48Mi"},"limits":{"cpu":"1","memory":"64Mi"}}}]}}}}'
echo "[$(now)] Limitando el worker a 64Mi y aplicando carga de memoria controlada"
kubectl -n "$NS" patch deployment worker --type=strategic -p "$OOM_PATCH" >/dev/null

DEADLINE=$((SECONDS + 120))
while true; do
  REASON="$(kubectl -n "$NS" get pods -l app=worker -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(next((c.get("lastState",{}).get("terminated",{}).get("reason","") for p in d["items"] for c in p.get("status",{}).get("containerStatuses",[]) if c.get("lastState",{}).get("terminated",{}).get("reason")), ""))
')"
  [[ "$REASON" == "OOMKilled" ]] && break
  (( SECONDS < DEADLINE )) || die "No se observó OOMKilled en 120s"
  sleep 2
done

echo "[$(now)] OK: se observó OOMKilled"
kubectl -n "$NS" get pods -l app=worker
echo "Restaura el límite con: chaos/oom.sh restore"
