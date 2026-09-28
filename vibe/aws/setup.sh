#!/bin/bash
# ==============================================================================
# VIBE - AWS Academy Sandbox Setup Script (~10-12 min total)
# Ejecutar desde AWS CloudShell o máquina local con credenciales de AWS activas.
# ==============================================================================
set -euo pipefail

STACK_NAME="vibe-k3s"
REGION="us-east-1"
KEY_NAME="${1:-}" # Opcional: nombre de la clave SSH si la tienes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/cloudformation.yaml"

echo "=========================================================="
echo " 🚀 VIBE Audio Platform - Despliegue en AWS Academy Sandbox"
echo "=========================================================="

# 1. Verificar credenciales AWS
echo "Verificando identidad de AWS..."
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Conectado a la cuenta: $ACCOUNT_ID (Region: $REGION)"

# 2. Desplegar Stack CloudFormation
echo "Desplegando stack CloudFormation '$STACK_NAME'..."
DEPLOY_ARGS=(
  --stack-name "$STACK_NAME"
  --template-body "file://$TEMPLATE_FILE"
  --region "$REGION"
  --capabilities CAPABILITY_IAM
)

if [ -n "$KEY_NAME" ]; then
  DEPLOY_ARGS+=(--parameters "ParameterKey=KeyName,ParameterValue=$KEY_NAME")
fi

aws cloudformation deploy "${DEPLOY_ARGS[@]}"

echo "Esperando que el stack termine de crearse..."
aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION" || true

# 3. Obtener Outputs
echo "Obteniendo datos de salida de la infraestructura..."
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].Outputs")

SERVER_IP=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="ServerPublicIP") | .OutputValue')
ELB_URL=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="LoadBalancerURL") | .OutputValue')
RAW_BUCKET=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="RawBucketName") | .OutputValue')
HLS_BUCKET=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="HlsBucketName") | .OutputValue')

echo "----------------------------------------------------------"
echo " 🌐 Servidor k3s Public IP: $SERVER_IP"
echo " 🌐 Load Balancer URL:     $ELB_URL"
echo " 🪣 Bucket Audio Raw:      $RAW_BUCKET"
echo " 🪣 Bucket Audio HLS:      $HLS_BUCKET"
echo "----------------------------------------------------------"

echo ""
echo "=== Pasos siguientes para completar el despliegue dentro del servidor ==="
echo "1. Conectate por SSH o Session Manager al servidor:"
echo "   ssh ubuntu@$SERVER_IP"
echo ""
echo "2. Clona el repositorio y ejecuta el instalador del cluster:"
echo "   git clone https://github.com/TU_USUARIO/vibe_k8s.git vibe"
echo "   cd vibe/vibe"
echo "   ./aws/cluster-init.sh $RAW_BUCKET $HLS_BUCKET"
echo ""
echo "Tu aplicacion estara disponible en: $ELB_URL"
