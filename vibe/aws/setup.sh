#!/bin/bash
# ==============================================================================
# VIBE - AWS Academy Sandbox Setup Script (~10-12 min total)
# Ejecutar desde AWS CloudShell o máquina local con credenciales de AWS activas.
# ==============================================================================
set -euo pipefail

STACK_NAME="vibe-k3s"
REGION="us-east-1"
KEY_NAME="${1:-vockey}" # Clave precreada por AWS Academy Sandbox

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/cloudformation.yaml"

for tool in aws jq python3; do
  command -v "$tool" >/dev/null || { echo "Falta la herramienta: $tool" >&2; exit 1; }
done
aws iam get-instance-profile --instance-profile-name LabInstanceProfile >/dev/null
aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null

# Usar la VPC predeterminada y subredes públicas explícitas, sin tocar la red del IDE.
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  echo "No hay VPC predeterminada. Hay que seleccionar una red compatible antes de desplegar." >&2
  exit 1
fi
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --output json)
SUBNET_COUNT=$(echo "$SUBNETS" | jq '[.Subnets[] | select(.DefaultForAz and .MapPublicIpOnLaunch)] | length')
if (( SUBNET_COUNT < 3 )); then
  echo "Se necesitan al menos tres subredes públicas predeterminadas en distintas zonas." >&2
  exit 1
fi
SUBNET_IDS=$(echo "$SUBNETS" | jq -r '[.Subnets[] | select(.DefaultForAz and .MapPublicIpOnLaunch)] | sort_by(.AvailabilityZone) | .[0:3] | map(.SubnetId) | join(",")')

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
  --template-file "$TEMPLATE_FILE"
  --region "$REGION"
  --no-fail-on-empty-changeset
  --parameter-overrides "KeyName=$KEY_NAME" "VpcId=$VPC_ID" "PublicSubnetIds=$SUBNET_IDS"
)

# Mantener el token al actualizar un stack; generar uno solo para un cluster nuevo.
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
  CLUSTER_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
  DEPLOY_ARGS+=("ClusterToken=$CLUSTER_TOKEN")
fi

aws cloudformation deploy "${DEPLOY_ARGS[@]}"

# deploy ya espera a que termine la creación o actualización y falla si no se completa.

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
echo "   ssh -i /ruta/labsuser.pem ec2-user@$SERVER_IP"
echo ""
echo "2. Copia vibe-aws.tar.gz y labsuser.pem al servidor, y ejecuta:"
echo "   tar -xzf vibe-aws.tar.gz"
echo "   cd vibe_k8s/vibe"
echo "   SSH_PRIVATE_KEY=/ruta/labsuser.pem bash aws/cluster-init.sh $RAW_BUCKET $HLS_BUCKET"
echo "   Usa la versión del proyecto que incluya las correcciones locales, no una copia antigua."
echo ""
echo "Tu aplicacion estara disponible en: $ELB_URL"
