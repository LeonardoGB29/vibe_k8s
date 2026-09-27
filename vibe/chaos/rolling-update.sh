#!/usr/bin/env bash
# Rolling update de la API bajo carga sin downtime.
# Cambia una variable de entorno (fuerza nuevo rollout) y cuenta errores mientras rota.
# Corre en otra terminal: make k6-load
set -euo pipefail
NS=vibe
VERSION=${1:-v$(date +%s)}

echo "[$(date +%T)] Rollout a versión $VERSION"
kubectl -n $NS set env deployment/api APP_VERSION=$VERSION >/dev/null
kubectl -n $NS patch deployment api -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"version\":\"$VERSION\"}}}}}" >/dev/null

ERR=0; OK=0
until kubectl -n $NS rollout status deployment/api --timeout=2s >/dev/null 2>&1; do
  if curl -sf -o /dev/null localhost/healthz; then OK=$((OK+1)); else ERR=$((ERR+1)); fi
  sleep 0.2
done
echo "[$(date +%T)] Rollout completo. Requests durante el rollout: $OK ok, $ERR error"
kubectl -n $NS get pods -l app=api -L version --no-headers | awk '{print "   ", $1, $3, $NF}'
echo "Para volver atrás: kubectl -n $NS rollout undo deployment/api"
