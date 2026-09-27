#!/usr/bin/env bash
# Simula la caída de un nodo worker de kind (detiene su contenedor Docker).
# Kubernetes marca el nodo NotReady y reprograma los pods en los otros nodos
# (por defecto tarda ~5 min por el toleration node.kubernetes.io/not-ready; ver README).
# Uso: chaos/node-down.sh [nodo=vibe-worker] [segundos_apagado=180]
set -euo pipefail
NODE=${1:-vibe-worker}
DOWN=${2:-180}

echo "Pods en $NODE antes de apagarlo:"
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE --no-headers | awk '{print "   ", $1"/"$2, $4}'

echo "[$(date +%T)] docker stop $NODE"
docker stop "$NODE" >/dev/null
T0=$(date +%s)

until kubectl get node "$NODE" | grep -q NotReady; do sleep 2; done
echo "[$(date +%T)] Nodo NotReady tras $(( $(date +%s) - T0 )) s. Observa: make watch"

sleep "$DOWN"
echo "[$(date +%T)] docker start $NODE"
docker start "$NODE" >/dev/null
until kubectl get node "$NODE" | grep -qw Ready; do sleep 2; done
echo "[$(date +%T)] Nodo de vuelta. Pods por nodo:"
kubectl -n vibe get pods -o wide --no-headers | awk '{print $7}' | sort | uniq -c
