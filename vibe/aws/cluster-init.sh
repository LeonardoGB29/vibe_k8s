#!/bin/bash
# ==============================================================================
# VIBE - Cluster Initialization Script (Runs on k3s-server)
# Configura Ingress (NodePort 30080), KEDA, construye imágenes y despliega VIBE.
# ==============================================================================
set -euo pipefail

RAW_BUCKET="${1:?Indica el bucket RawBucketName del stack}"
HLS_BUCKET="${2:?Indica el bucket HlsBucketName del stack}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export IMAGE_DISTRIBUTION="${IMAGE_DISTRIBUTION:-ssm}"
export IMAGE_BUCKET="${IMAGE_BUCKET:-$RAW_BUCKET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== [1/6] Esperando que los nodos del cluster estén Ready ==="
DEADLINE=$((SECONDS + 600))
until kubectl get nodes -o json 2>/dev/null | jq -e '[.items[] | select(.status.conditions[] | .type == "Ready" and .status == "True")] | length == 4' >/dev/null; do
    if (( SECONDS >= DEADLINE )); then
        echo "No llegaron a estar Ready los cuatro nodos en 10 minutos" >&2
        exit 1
    fi
    echo "Esperando los cuatro nodos Ready..."
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
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.21.0/keda-2.21.0.yaml
kubectl wait --for=condition=Established crd/scaledobjects.keda.sh --timeout=180s
kubectl -n keda rollout status deployment/keda-operator --timeout=180s
kubectl -n keda rollout status deployment/keda-metrics-apiserver --timeout=180s
kubectl -n keda rollout status deployment/keda-admission --timeout=180s

echo "=== [4/6] Construyendo imágenes de microservicios y distribuyendo a los nodos ==="
chmod +x "$SCRIPT_DIR/build-and-load.sh"
"$SCRIPT_DIR/build-and-load.sh"

echo "=== [5/6] Configurando variables de entorno para AWS S3 ==="
cd "$REPO_ROOT"

# Crear namespace si no existe
kubectl apply -f k8s/00-namespace.yaml

# Obtener credenciales temporales de la instancia (LabRole/LabInstanceProfile)
# o usar token de sesión si fue provisto
TOKEN=$(curl -fsS --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
ROLE_NAME=$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ || true)

if [ -n "$ROLE_NAME" ]; then
    CREDS=$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
    echo "$CREDS" | jq -e '.Code == "Success" and (.AccessKeyId | type == "string") and (.SecretAccessKey | type == "string") and (.Token | type == "string")' >/dev/null
    AWS_AK=$(echo "$CREDS" | jq -r '.AccessKeyId')
    AWS_SK=$(echo "$CREDS" | jq -r '.SecretAccessKey')
    AWS_ST=$(echo "$CREDS" | jq -r '.Token')
else
    AWS_AK="${AWS_ACCESS_KEY_ID:?No hay rol EC2 ni AWS_ACCESS_KEY_ID}"
    AWS_SK="${AWS_SECRET_ACCESS_KEY:?No hay rol EC2 ni AWS_SECRET_ACCESS_KEY}"
    AWS_ST="${AWS_SESSION_TOKEN:?Indica AWS_SESSION_TOKEN para las credenciales temporales}"
fi

# Generar ConfigMap y Secret para S3
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vibe-config
  namespace: vibe
data:
  DATABASE_URL: postgresql+psycopg://vibe:vibe@postgres:5432/vibe
  REDIS_URL: redis://redis:6379/0
  MINIO_ENDPOINT: s3.us-east-1.amazonaws.com
  MINIO_SECURE: "true"
  AWS_REGION: us-east-1
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
  namespace: vibe
type: Opaque
stringData:
  POSTGRES_USER: vibe
  POSTGRES_PASSWORD: vibe
  POSTGRES_DB: vibe
  MINIO_ACCESS_KEY: "$AWS_AK"
  MINIO_SECRET_KEY: "$AWS_SK"
  MINIO_SESSION_TOKEN: "$AWS_ST"
EOF

echo "=== [6/6] Desplegando Postgres, Redis y los 5 Microservicios ==="
kubectl apply -f k8s/20-postgres.yaml
kubectl apply -f k8s/22-redis.yaml

echo "Esperando que Postgres y Redis esten listos..."
kubectl rollout status statefulset/postgres -n vibe --timeout=120s
kubectl rollout status deployment/redis -n vibe --timeout=60s

kubectl apply -f k8s/30-frontend.yaml
kubectl apply -f k8s/31-catalog-api.yaml
kubectl apply -f k8s/32-upload-api.yaml
kubectl apply -f k8s/33-stream-api.yaml
kubectl apply -f k8s/34-worker.yaml
kubectl apply -f "$SCRIPT_DIR/ingress.yaml"
kubectl apply -f k8s/50-hpa.yaml
kubectl apply -f k8s/51-keda-worker.yaml
kubectl -n vibe patch scaledobject worker --type=merge -p '{"spec":{"maxReplicaCount":8}}'
kubectl apply -f k8s/60-pdb.yaml

echo "Esperando que todos los microservicios inicien..."
kubectl rollout status deployment/frontend -n vibe --timeout=120s
kubectl rollout status deployment/catalog-api -n vibe --timeout=120s
kubectl rollout status deployment/upload-api -n vibe --timeout=120s
kubectl rollout status deployment/stream-api -n vibe --timeout=120s
kubectl rollout status deployment/worker -n vibe --timeout=120s

echo "=========================================================="
echo " 🎉 VIBE Microservicios desplegados exitosamente en AWS!"
echo "=========================================================="
kubectl get pods -n vibe -o wide
echo ""
kubectl get ingress -n vibe
