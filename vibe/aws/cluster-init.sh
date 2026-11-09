#!/bin/bash
# ==============================================================================
# VIBE - Cluster Initialization Script (Runs on k3s-server)
# Configura Ingress (NodePort 30080), KEDA y despliega VIBE con las imágenes publicadas
# en GHCR (IMAGE_TAG): cualquier nodo, incluidos los que se añadan después, las descarga.
# ==============================================================================
set -euo pipefail

RAW_BUCKET="${1:?Indica el bucket RawBucketName del stack}"
HLS_BUCKET="${2:?Indica el bucket HlsBucketName del stack}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"
: "${IMAGE_TAG:?Indica IMAGE_TAG (sha-<commit> publicado en GHCR); lo fija aws/deploy-aws.sh}"
: "${REGISTRY_OWNER:?Indica REGISTRY_OWNER (propietario en minusculas de las imagenes GHCR)}"

# Entorno que se esta inicializando (cada uno tiene su propio clúster).
VIBE_ENVIRONMENT="${VIBE_ENVIRONMENT:-desarrollo}"
VIBE_EXPECTED_NODES="${VIBE_EXPECTED_NODES:-4}"
case "$VIBE_ENVIRONMENT" in
  desarrollo) NAMESPACE=vibe ;;
  staging) NAMESPACE=vibe-staging ;;
  produccion) NAMESPACE=vibe-produccion ;;
  *) echo "VIBE_ENVIRONMENT debe ser desarrollo, staging o produccion" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== [1/6] Esperando que los nodos del cluster estén Ready ==="
DEADLINE=$((SECONDS + 600))
until kubectl get nodes -o json 2>/dev/null | jq -e '[.items[] | select(.status.conditions[] | .type == "Ready" and .status == "True")] | length >= '"$VIBE_EXPECTED_NODES" >/dev/null; do
    if (( SECONDS >= DEADLINE )); then
        echo "No llegaron a estar Ready los $VIBE_EXPECTED_NODES nodos en 10 minutos" >&2
        exit 1
    fi
    echo "Esperando los $VIBE_EXPECTED_NODES nodos Ready..."
    sleep 5
done
kubectl get nodes -o wide

echo "=== [2/6] Instalando Traefik (NodePort 30080 para el ELB) ==="
kubectl apply -f "$SCRIPT_DIR/traefik.yaml"
DEADLINE=$((SECONDS + 300))
until kubectl -n traefik get deployment traefik >/dev/null 2>&1; do
    if (( SECONDS >= DEADLINE )); then
        kubectl -n kube-system get jobs,pods
        echo "El controlador Helm de k3s no creó Traefik" >&2
        exit 1
    fi
    sleep 5
done
kubectl -n traefik rollout status deployment/traefik --timeout=300s

echo "=== [3/6] Instalando KEDA (para autoescalado de workers por cola Redis) ==="
KEDA_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/k8s/KEDA_VERSION")"  # misma version que el CI
kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/${KEDA_VERSION}/keda-${KEDA_VERSION#v}.yaml"
kubectl wait --for=condition=Established crd/scaledobjects.keda.sh --timeout=180s
kubectl -n keda rollout status deployment/keda-operator --timeout=180s
kubectl -n keda rollout status deployment/keda-metrics-apiserver --timeout=180s
kubectl -n keda rollout status deployment/keda-admission --timeout=180s

# Autoescalado de nodos: solo si el entorno tiene un Auto Scaling Group de agentes (staging).
# El rol de los nodos solo puede describir ASG cuando Terraform habilito cluster_autoscaler.
ASG_NAME="vibe-${VIBE_ENVIRONMENT}-k3s-agents"
if [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
        --query 'length(AutoScalingGroups)' --output text 2>/dev/null || echo 0)" = "1" ]; then
    echo "=== [3b/6] Instalando Cluster Autoscaler (ASG $ASG_NAME) ==="
    sed -e "s/__CLUSTER_NAME__/vibe-${VIBE_ENVIRONMENT}/g" -e "s/__REGION__/${AWS_DEFAULT_REGION}/g" \
        "$SCRIPT_DIR/cluster-autoscaler.yaml" | kubectl apply -f -
    kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout=180s
    # Limpieza de nodos huerfanos (agentes que Terraform destruyo): una pasada ya y despues cada 2 minutos.
    kubectl -n kube-system create job "node-pruner-init-$(date +%s)" --from=cronjob/node-pruner || true
else
    echo "Sin Auto Scaling Group de agentes en $VIBE_ENVIRONMENT: no se instala el Cluster Autoscaler."
fi

echo "=== [4/6] Imágenes: se usarán las publicadas en GHCR (${IMAGE_TAG}) ==="
# No se construye nada en el servidor: las imágenes las construye y publica el CI, y
# cada nodo (también los agentes que se añadan al escalar) las descarga del registro.
SERVER_FREE_MIB="$(df -Pm / | awk 'NR == 2 {print $4}')"
echo "Espacio libre en el servidor: ${SERVER_FREE_MIB} MiB"
if (( SERVER_FREE_MIB < ${VIBE_MIN_SERVER_MIB:-3000} )); then
    echo "Espacio insuficiente en el servidor: se requieren al menos ${VIBE_MIN_SERVER_MIB:-3000} MiB libres para las imágenes." >&2
    exit 1
fi

echo "=== [5/6] Configurando variables de entorno para AWS S3 ==="
cd "$REPO_ROOT"

# Crear namespace si no existe
kubectl apply -f "k8s/overlays/$VIBE_ENVIRONMENT/namespace.yaml"

# Acceso a S3: los pods usan el rol de la instancia (modules/node-iam) con credenciales
# temporales que el propio cliente renueva (MINIO_AUTH=instance-role). No se copia ninguna
# clave ni token a un Secret, asi que no hay nada que caduque ni que se pueda filtrar.
# Requisito: los nodos permiten que los pods lleguen a IMDSv2 (http_put_response_hop_limit = 2).

# Generar ConfigMap y Secret de la aplicacion
if kubectl -n "$NAMESPACE" get secret vibe-secrets >/dev/null 2>&1; then
    POSTGRES_PASSWORD="$(kubectl -n "$NAMESPACE" get secret vibe-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 --decode)"
else
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 24)}"
fi
if [ "$VIBE_ENVIRONMENT" = "desarrollo" ]; then
    DATABASE_URL="postgresql+psycopg://vibe:${POSTGRES_PASSWORD}@postgres:5432/vibe"
else
    # Staging/produccion usan el RDS de su entorno: deploy-aws.sh dejo la URL en SSM.
    DATABASE_URL="$(aws ssm get-parameter --name "/vibe-${VIBE_ENVIRONMENT}/database-url" \
        --with-decryption --query Parameter.Value --output text)"
    [ -n "$DATABASE_URL" ] || { echo "Falta /vibe-${VIBE_ENVIRONMENT}/database-url en SSM" >&2; exit 1; }
fi
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vibe-config
  namespace: ${NAMESPACE}
data:
  REDIS_URL: redis://redis:6379/0
  MINIO_ENDPOINT: s3.${AWS_DEFAULT_REGION}.amazonaws.com
  MINIO_SECURE: "true"
  MINIO_AUTH: instance-role
  AWS_REGION: ${AWS_DEFAULT_REGION}
  BUCKET_RAW: "$RAW_BUCKET"
  BUCKET_HLS: "$HLS_BUCKET"
  QUEUE_NAME: transcode
  HLS_BITRATES: 64k,128k
  HLS_SEGMENT_SECONDS: "6"
---
apiVersion: v1
kind: Secret
metadata:
  name: vibe-secrets
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  POSTGRES_USER: vibe
  POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
  POSTGRES_DB: vibe
  DATABASE_URL: "${DATABASE_URL}"
EOF

# kubectl apply no elimina claves que ya existian en el Secret: se borran las claves de S3 de
# despliegues anteriores (credenciales temporales caducadas). Cada una por separado: el parche
# JSON falla entero si falta alguna.
for key in MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_SESSION_TOKEN; do
    kubectl -n "$NAMESPACE" patch secret vibe-secrets --type=json         -p "[{\"op\":\"remove\",\"path\":\"/data/${key}\"}]" >/dev/null 2>&1 || true
done

echo "=== [6/6] Desplegando Postgres, Redis y los 5 Microservicios (overlay $VIBE_ENVIRONMENT, imágenes ${IMAGE_TAG}) ==="
# deploy-ghcr.sh aplica el overlay con las imágenes de GHCR, espera los rollouts, comprueba
# la salud y restaura la revisión anterior si algo falla (el mismo script que usa el CD).
TARGET_ENVIRONMENT="$VIBE_ENVIRONMENT" IMAGE_TAG="$IMAGE_TAG" REGISTRY_OWNER="$REGISTRY_OWNER" \
    REPO="${REGISTRY_REPO:-vibe_k8s}" bash "$SCRIPT_DIR/deploy-ghcr.sh"

echo "Esperando que Redis este listo..."
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=60s

# Los pods solo leen vibe-config y vibe-secrets al arrancar: se reinician para aplicar cambios de
# configuracion (por ejemplo MINIO_AUTH). Si ya estaban al dia, es un reinicio rapido y sin cortes.
for d in frontend catalog-api upload-api stream-api worker; do
    kubectl -n "$NAMESPACE" rollout restart "deployment/$d"
done
for d in frontend catalog-api upload-api stream-api worker; do
    kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=240s
done

echo "=========================================================="
echo " VIBE Microservicios desplegados exitosamente en AWS!"
echo "=========================================================="
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
kubectl get services -n "$NAMESPACE" -o wide
echo ""
kubectl get ingress -n "$NAMESPACE"
