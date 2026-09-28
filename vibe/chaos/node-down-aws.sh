#!/usr/bin/env bash
# ==============================================================================
# VIBE Chaos Engineering: Caída real de nodo en AWS EC2
# Apaga una instancia EC2 de worker (k3s-agent) con 'aws ec2 stop-instances'.
# Kubernetes detectará NotReady y reprogramará los pods en los nodos restantes.
# ==============================================================================
set -euo pipefail

NODE_NAME=${1:-k3s-agent-1}
DOWN_SECONDS=${2:-120}

echo "=== [Chaos Test] Simulación de falla física de nodo en AWS ==="
echo "Buscando instancia EC2 correspondiente al nodo '$NODE_NAME'..."

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vibe-$NODE_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
  echo "Error: No se encontró la instancia EC2 para el nodo vibe-$NODE_NAME en estado running."
  echo "Verifica con: aws ec2 describe-instances --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==\`Name\`].Value|[0],State:State.Name}'"
  exit 1
fi

echo "Instancia encontrada: $INSTANCE_ID ($NODE_NAME)"
echo ""
echo "Pods corriendo en $NODE_NAME antes de apagar:"
kubectl get pods -n vibe -o wide --field-selector spec.nodeName="$NODE_NAME" --no-headers | awk '{print "   ", $1, $3, $7}' || true

echo ""
echo "[$(date +%T)] ⚠️ Deteniendo instancia EC2: $INSTANCE_ID..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null

T0=$(date +%s)
echo "Esperando que Kubernetes marque el nodo como NotReady..."
while true; do
  STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" != "True" ]; then
    break
  fi
  sleep 3
done

ELAPSED=$(( $(date +%s) - T0 ))
echo "[$(date +%T)] 🚨 Nodo '$NODE_NAME' detectado como NotReady tras ${ELAPSED}s!"
echo "Los pods serán reprogramados en los nodos restantes de acuerdo al PDB y afinidad."
echo "Puedes monitorear en tiempo real con: kubectl get pods -n vibe -o wide -w"

echo ""
echo "Manteniendo la instancia apagada durante ${DOWN_SECONDS}s..."
sleep "$DOWN_SECONDS"

echo ""
echo "[$(date +%T)] 🔄 Encendiendo instancia EC2 nuevamente..."
aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null

echo "Esperando que el nodo vuelva a estado Ready..."
until kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; do
  sleep 4
done

echo "[$(date +%T)] ✅ Nodo '$NODE_NAME' ha vuelto a estar Ready!"
echo ""
echo "Distribución final de pods en el namespace 'vibe':"
kubectl get pods -n vibe -o wide --no-headers | awk '{print $7}' | sort | uniq -c
