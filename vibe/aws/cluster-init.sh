#!/bin/bash
# ==============================================================================
# VIBE - Cluster Initialization Script (Runs on k3s-server)
# Configura Ingress (NodePort 30080), KEDA, construye imágenes y despliega VIBE.
# ==============================================================================
set -euo pipefail

RAW_BUCKET="${1:-vibe-audio-raw}"
HLS_BUCKET="${2:-vibe-audio-hls}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== [1/6] Esperando que los nodos del cluster estén Ready ==="
while [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready")" -lt 4 ]; do
    echo "Esperando nodos... ($(kubectl get nodes --no-headers 2>/dev/null | grep -c 'Ready')/4 listos)"
    sleep 5
done
kubectl get nodes -o wide

echo "=== [2/6] Instalando Ingress NGINX (NodePort 30080 para el ELB) ==="
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/baremetal/deploy.yaml

echo "Esperando el Deployment de ingress-nginx..."
kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment/ingress-nginx-controller \
  --timeout=180s || true

# Configurar el NodePort 30080 exactamente para el ELB
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value":30080}]' || true

echo "=== [3/6] Instalando KEDA (para autoescalado de workers por cola Redis) ==="
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.15.1/keda-2.15.1.yaml

echo "=== [4/6] Construyendo imágenes de microservicios y distribuyendo a los nodos ==="
chmod +x "$SCRIPT_DIR/build-and-load.sh"
"$SCRIPT_DIR/build-and-load.sh"

echo "=== [5/6] Configurando variables de entorno para AWS S3 ==="
cd "$REPO_ROOT"

# Crear namespace si no existe
kubectl apply -f k8s/00-namespace.yaml

# Obtener credenciales temporales de la instancia (LabRole/LabInstanceProfile)
# o usar token de sesión si fue provisto
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ || true)

if [ -n "$ROLE_NAME" ]; then
    CREDS=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
    AWS_AK=$(echo "$CREDS" | jq -r '.AccessKeyId')
    AWS_SK=$(echo "$CREDS" | jq -r '.SecretAccessKey')
    AWS_ST=$(echo "$CREDS" | jq -r '.Token')
else
    AWS_AK="${AWS_ACCESS_KEY_ID:-vibeadmin}"
    AWS_SK="${AWS_SECRET_ACCESS_KEY:-vibesecret123}"
    AWS_ST="${AWS_SESSION_TOKEN:-}"
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
kubectl apply -f k8s/40-ingress.yaml
kubectl apply -f k8s/50-hpa.yaml
kubectl apply -f k8s/51-keda-worker.yaml
kubectl apply -f k8s/60-pdb.yaml

echo "Esperando que todos los microservicios inicien..."
kubectl rollout status deployment/frontend -n vibe --timeout=120s
kubectl rollout status deployment/catalog-api -n vibe --timeout=120s
kubectl rollout status deployment/upload-api -n vibe --timeout=120s
kubectl rollout status deployment/stream-api -n vibe --timeout=120s

echo "=========================================================="
echo " 🎉 VIBE Microservicios desplegados exitosamente en AWS!"
echo "=========================================================="
kubectl get pods -n vibe -o wide
echo ""
kubectl get ingress -n vibe
