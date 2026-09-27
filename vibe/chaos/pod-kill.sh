#!/usr/bin/env bash
# Mata pods de la API cada N segundos mientras corre una prueba de carga.
# Mide cuánto tarda el ReplicaSet en recrearlos y si el servicio sigue respondiendo.
# Uso: chaos/pod-kill.sh [intervalo_seg=15] [veces=6] [app=api]
set -euo pipefail
NS=vibe
INTERVAL=${1:-15}
TIMES=${2:-6}
APP=${3:-api}

for i in $(seq 1 "$TIMES"); do
  POD=$(kubectl -n $NS get pods -l app=$APP --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  echo "[$(date +%T)] ($i/$TIMES) Matando $POD"
  T0=$(date +%s)
  kubectl -n $NS delete pod "$POD" --grace-period=0 --force >/dev/null 2>&1 || true
  # espera a que vuelva a haber todas las réplicas listas
  until [[ "$(kubectl -n $NS get deploy $APP -o jsonpath='{.status.readyReplicas}')" == "$(kubectl -n $NS get deploy $APP -o jsonpath='{.spec.replicas}')" ]]; do sleep 1; done
  echo "[$(date +%T)] Recuperado en $(( $(date +%s) - T0 )) s"
  kubectl -n $NS get pods -l app=$APP -o wide --no-headers | awk '{print "   ", $1, $3, $7}'
  sleep "$INTERVAL"
done
