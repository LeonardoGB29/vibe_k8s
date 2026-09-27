#!/usr/bin/env bash
# Radiografía del cluster VIBE en una sola pantalla: nodos, pods (labels, nodo, CPU/RAM en uso,
# requests/limits), autoescalado, cola y últimos eventos.
# Uso: tools/cluster-status.sh        (una vez)
#      tools/cluster-status.sh -w     (se refresca cada 3 s, Ctrl+C para salir)
set -u
NS=vibe
B="\033[1m"; C="\033[36m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; N="\033[0m"

title() { echo -e "\n${B}${C}== $1 ==${N}"; }

show() {
  echo -e "${B}VIBE cluster  ·  $(date +%H:%M:%S)${N}"

  title "Nodos"
  kubectl get nodes -o custom-columns='NODO:.metadata.name,ROL:.metadata.labels.node-role\.kubernetes\.io/control-plane,ESTADO:.status.conditions[-1].type,CPU:.status.allocatable.cpu,RAM:.status.allocatable.memory' 2>/dev/null \
    | sed 's/<none>/worker/; s/ROL/       ROL/'
  kubectl top nodes 2>/dev/null | sed 's/^/  uso: /' || echo "  (metrics-server aún sin datos)"

  title "Pods por nodo (app, estado, reinicios, IP)"
  kubectl -n $NS get pods -o custom-columns='NODO:.spec.nodeName,POD:.metadata.name,APP:.metadata.labels.app,ESTADO:.status.phase,LISTO:.status.containerStatuses[0].ready,REINICIOS:.status.containerStatuses[0].restartCount,IP:.status.podIP' --sort-by=.spec.nodeName 2>/dev/null

  title "Uso actual CPU / RAM por pod"
  kubectl -n $NS top pods --sort-by=cpu 2>/dev/null || echo "  (metrics-server aún sin datos, espera 1 min)"

  title "Requests y limits configurados"
  kubectl -n $NS get pods -o custom-columns='POD:.metadata.name,REQ_CPU:.spec.containers[0].resources.requests.cpu,REQ_RAM:.spec.containers[0].resources.requests.memory,LIM_CPU:.spec.containers[0].resources.limits.cpu,LIM_RAM:.spec.containers[0].resources.limits.memory' 2>/dev/null

  title "Réplicas y autoescalado"
  kubectl -n $NS get deploy -o custom-columns='DEPLOY:.metadata.name,DESEADAS:.spec.replicas,LISTAS:.status.readyReplicas,DISPONIBLES:.status.availableReplicas' 2>/dev/null
  echo
  kubectl -n $NS get hpa 2>/dev/null
  echo
  kubectl -n $NS get scaledobject 2>/dev/null | awk '{print $1, "min="$4, "max="$5, "ready="$6, "active="$7}'

  title "Cola y catálogo"
  QLEN=$(kubectl -n $NS exec deploy/redis -- redis-cli llen transcode 2>/dev/null || echo "?")
  echo "  trabajos en cola (redis 'transcode'): ${QLEN}"
  if command -v curl >/dev/null; then
    STATS=$(curl -s --max-time 2 localhost/api/stats 2>/dev/null)
    [[ -n "$STATS" ]] && echo "  api/stats: $STATS" || echo "  api/stats: (ingress no responde en localhost)"
  fi

  title "Volúmenes persistentes"
  kubectl -n $NS get pvc -o custom-columns='PVC:.metadata.name,ESTADO:.status.phase,TAMAÑO:.status.capacity.storage' 2>/dev/null

  title "Últimos eventos"
  kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -8 | awk '{ $1=""; print "  "$0 }'
}

if [[ "${1:-}" == "-w" ]]; then
  while true; do clear; show; sleep 3; done
else
  show
fi
