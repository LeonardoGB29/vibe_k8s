#!/usr/bin/env bash
# Uso: chaos/oom.sh | chaos/oom.sh restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_cmds kubectl curl python3
require_cluster

if [[ "${1:-}" == "restore" ]]; then
  kubectl -n "$NS" set resources deployment/worker --limits=cpu=1,memory=512Mi >/dev/null
  kubectl -n "$NS" rollout status deployment/worker --timeout=180s
  echo "Límite restaurado a 512Mi"
  exit 0
fi
[[ $# -eq 0 ]] || die "Uso: chaos/oom.sh [restore]"

AUDIO="${UPLOAD_FILE:-data/audio/001 - DJ Replica - Lunar Horizon.mp3}"
[[ -f "$AUDIO" ]] || die "Falta $AUDIO; ejecuta make gen-audio"
kubectl -n "$NS" set resources deployment/worker --limits=cpu=1,memory=48Mi >/dev/null
kubectl -n "$NS" rollout status deployment/worker --timeout=180s

echo "[$(now)] Encolando audio para forzar presión de memoria"
curl -fsS --max-time 120 \
  -F "file=@$AUDIO;type=audio/mpeg" \
  -F "title=OOM test $(date '+%s')" -F 'artist=chaos' -F 'album=OOM' \
  "$BASE_URL/api/upload" >/dev/null

DEADLINE=$((SECONDS + 240))
while true; do
  REASON="$(kubectl -n "$NS" get pods -l app=worker -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(next((c.get("lastState",{}).get("terminated",{}).get("reason","") for p in d["items"] for c in p.get("status",{}).get("containerStatuses",[]) if c.get("lastState",{}).get("terminated",{}).get("reason")), ""))
')"
  [[ "$REASON" == "OOMKilled" ]] && break
  (( SECONDS < DEADLINE )) || die "No se observó OOMKilled en 240s"
  sleep 2
done

echo "[$(now)] OK: se observó OOMKilled"
kubectl -n "$NS" get pods -l app=worker
echo "Restaura el límite con: chaos/oom.sh restore"
