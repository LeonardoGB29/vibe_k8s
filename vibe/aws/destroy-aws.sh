#!/usr/bin/env bash
# Elimina la infraestructura Terraform de un entorno: bash aws/destroy-aws.sh [desarrollo|staging|produccion] (par de deploy-aws.sh).
# Terraform pide confirmacion interactiva. Los buckets S3 (state y audio) los crea
# deploy-aws.sh con AWS CLI y NO se borran aqui: vacialos/eliminalos a mano
# si de verdad quieres limpiar la cuenta.
# La CLI de AWS en Windows falla con 'charmap' al imprimir salidas con caracteres no ASCII (p. ej. flechas de SSM).
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${1:-${VIBE_ENVIRONMENT:-desarrollo}}"
case "$ENVIRONMENT" in desarrollo|staging|produccion) ;; *) echo "ERROR: entorno debe ser desarrollo, staging o produccion." >&2; exit 2 ;; esac
ENV_DIR="$SCRIPT_DIR/../terraform/envs/$ENVIRONMENT"
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-2}}"

# shellcheck source=lib-s3.sh
source "$SCRIPT_DIR/lib-s3.sh"
command -v terraform >/dev/null 2>&1 || { echo "ERROR: falta terraform." >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS CLI sin credenciales activas." >&2; exit 1; }
export_aws_credentials

cd "$ENV_DIR"
if [[ ! -f backend.hcl ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  printf 'bucket = "%s"\n' "vibe-tfstate-${ACCOUNT_ID}" > backend.hcl
fi
terraform init -backend-config=backend.hcl -lockfile=readonly -input=false
terraform destroy -var="region=$REGION"
echo "Infraestructura de $ENVIRONMENT destruida. Los buckets S3 se conservan (ver cabecera del script)."
# El parametro con la DATABASE_URL (staging/produccion) lo crea deploy-aws.sh fuera de Terraform.
if [[ "$ENVIRONMENT" != "desarrollo" ]]; then
  aws ssm delete-parameter --name "/vibe-${ENVIRONMENT}/database-url" --region "$REGION" >/dev/null 2>&1 || true
fi
