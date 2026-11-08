#!/usr/bin/env bash
# Prepara la cuenta AWS (una sola vez, ANTES de desplegar nada):
#   1. bucket del state de Terraform (vibe-tfstate-<cuenta>)
#   2. guardian de creditos (Lambda que pausa EC2/RDS de VIBE si los creditos bajan del umbral)
#   3. roles OIDC para GitHub Actions (sin claves ni tokens de sesion)
# Uso:  VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh   (opcional: STOP_BELOW_USD=20)
set -Eeuo pipefail

REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-2}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_DIR="$SCRIPT_DIR/../terraform/account"

die() { echo "ERROR: $*" >&2; exit 1; }
for tool in aws terraform; do
  command -v "$tool" >/dev/null 2>&1 || die "No encuentro '$tool'."
done
# shellcheck source=lib-s3.sh
source "$SCRIPT_DIR/lib-s3.sh"

export AWS_DEFAULT_REGION="$REGION"
aws sts get-caller-identity >/dev/null || die "AWS CLI sin credenciales activas (usa AWS_PROFILE o 'aws login')."
export_aws_credentials
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="vibe-tfstate-${ACCOUNT_ID}"
ALERT_EMAIL="${VIBE_ALERT_EMAIL:-}"
STOP_BELOW="${STOP_BELOW_USD:-20}"

echo "Cuenta: $ACCOUNT_ID   Region: $REGION"
echo "Se aplicara (solo lo que falte): bucket de state, Lambda guardian (pausa EC2/RDS de VIBE bajo ${STOP_BELOW} USD de credito) y el usuario IAM github-vibe-deploy de CI (permisos minimos, sin clave)."
echo "Costo estimado: ~0 USD/mes."
read -r -p "Escribe continuar para seguir: " CONFIRM
[[ "$CONFIRM" == "continuar" ]] || die "Cancelado."

ensure_s3_bucket "$STATE_BUCKET"

cd "$ACCOUNT_DIR"
printf 'bucket = "%s"\n' "$STATE_BUCKET" > backend.hcl
terraform init -backend-config=backend.hcl -lockfile=readonly -input=false
terraform apply \
  -var="region=$REGION" -var="alert_email=$ALERT_EMAIL" -var="stop_below_usd=$STOP_BELOW"

echo
echo "Listo. Guardian de creditos desplegado (Lambda vibe-credit-guard, revisa el saldo cada hora)."
echo "State de Terraform: bucket $STATE_BUCKET"
CI_USER="$(terraform output -raw ci_deploy_user 2>/dev/null || true)"
if [[ -n "$CI_USER" ]]; then
  echo "Usuario de CI creado: $CI_USER (permisos minimos de despliegue)."
  echo "Crea su clave tu mismo (no queda en Terraform) y guardala como secretos de los GitHub Environments:"
  echo "  aws iam create-access-key --user-name $CI_USER"
  echo "  Secrets: AWS_ACCESS_KEY_ID y AWS_SECRET_ACCESS_KEY.   Variable: AWS_REGION=$REGION"
fi
[[ -n "$ALERT_EMAIL" ]] && echo "Confirma la suscripcion SNS que llegara a $ALERT_EMAIL."
echo "Ver el saldo que lee el guardian (solo detiene recursos si esta bajo el umbral): aws lambda invoke --function-name vibe-credit-guard /dev/stdout"
