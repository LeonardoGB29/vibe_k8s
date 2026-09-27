#!/usr/bin/env bash
# Fuerza OOMKilled en el worker bajando su límite de memoria y encolando trabajo.
# Kubernetes reinicia el contenedor (CrashLoopBackOff) sin intervención.
# Uso: chaos/oom.sh        (aplica)   |   chaos/oom.sh restore  (restaura 512Mi)
set -euo pipefail
NS=vibe
if [[ "${1:-}" == "restore" ]]; then
  kubectl -n $NS set resources deployment/worker --limits=memory=512Mi
  echo "Límite restaurado a 512Mi"
  exit 0
fi
kubectl -n $NS set resources deployment/worker --limits=memory=48Mi
echo "Límite bajado a 48Mi. Sube un audio y observa:"
echo "  kubectl -n $NS get pods -l app=worker -w"
echo "  kubectl -n $NS describe pod -l app=worker | grep -A3 'Last State'"
