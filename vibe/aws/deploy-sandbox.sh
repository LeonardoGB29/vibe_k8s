#!/usr/bin/env bash
# Un solo comando para desplegar VIBE en AWS Academy Cloud Foundations Sandbox.
set -Eeuo pipefail

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$VIBE_DIR/.." && pwd)"
ENV_DIR="$VIBE_DIR/terraform/envs/desarrollo"
ARCHIVE="${TMPDIR:-/tmp}/vibe-aws.tar.gz"
TF_PLAN="$(mktemp "${TMPDIR:-/tmp}/vibe-tfplan.XXXXXX")"
REQUEST_FILE=""

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() {
  rm -f "$TF_PLAN"
  [[ -z "$REQUEST_FILE" ]] || rm -f "$REQUEST_FILE"
}
trap cleanup EXIT

ensure_s3_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
    echo "Reutilizando bucket existente: $bucket"
  else
    echo "Creando bucket: $bucket"
    aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
  fi

  aws s3api put-public-access-block \
    --bucket "$bucket" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --region "$REGION"
  aws s3api put-bucket-encryption \
    --bucket "$bucket" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    --region "$REGION"
  aws s3api put-bucket-versioning \
    --bucket "$bucket" \
    --versioning-configuration Status=Enabled \
    --region "$REGION"

  local policy_file
  policy_file="$(mktemp)"
  jq -n --arg bucket "$bucket" '{Version:"2012-10-17",Statement:[{Sid:"DenyInsecureTransport",Effect:"Deny",Principal:"*",Action:"s3:*",Resource:[("arn:aws:s3:::"+$bucket),("arn:aws:s3:::"+$bucket+"/*")],Condition:{Bool:{"aws:SecureTransport":"false"}}}]}' > "$policy_file"
  aws s3api put-bucket-policy --bucket "$bucket" --policy "file://$policy_file" --region "$REGION"
  rm -f "$policy_file"
}

for tool in aws terraform jq tar curl; do
  command -v "$tool" >/dev/null 2>&1 || die "No encuentro '$tool'. Ejecuta el script desde Lab IDE con las herramientas instaladas."
done

export AWS_DEFAULT_REGION="$REGION"
aws sts get-caller-identity >/dev/null || die "Las credenciales AWS no son válidas o expiraron. Reinicia el Lab y vuelve a ejecutar el script."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"

echo "Cuenta AWS: $ACCOUNT_ID"
echo "Identidad:  $CALLER_ARN"
echo "Región:     $REGION"
echo "Se desplegarán cuatro instancias EC2, un ELB y tres buckets S3."
read -r -p "Escribe desplegar para continuar: " CONFIRM
[[ "$CONFIRM" == "desplegar" ]] || die "Despliegue cancelado."

echo "=== 1/6 Creando/configurando los buckets con AWS CLI ==="
STATE_BUCKET="vibe-tfstate-${ACCOUNT_ID}"
RAW_BUCKET="vibe-desarrollo-audio-raw-${ACCOUNT_ID}"
HLS_BUCKET="vibe-desarrollo-audio-hls-${ACCOUNT_ID}"
ensure_s3_bucket "$STATE_BUCKET"
ensure_s3_bucket "$RAW_BUCKET"
ensure_s3_bucket "$HLS_BUCKET"

echo "=== 2/6 Creando la infraestructura ==="
cd "$ENV_DIR"
printf 'bucket = "%s"\n' "$STATE_BUCKET" > backend.hcl
terraform init -backend-config=backend.hcl -lockfile=readonly
terraform plan -out="$TF_PLAN"
terraform apply -auto-approve "$TF_PLAN"

SERVER_ID="$(terraform output -raw server_instance_id)"
ELB_URL="$(terraform output -raw elb_url)"

echo "=== 3/6 Empaquetando y subiendo la aplicación ==="
tar -czf "$ARCHIVE" \
  --exclude='vibe/data/audio/*.mp3' \
  --exclude='vibe/data/audio/*.wav' \
  --transform='s,^vibe$,vibe_k8s/vibe,' \
  --transform='s,^vibe/,vibe_k8s/vibe/,' \
  -C "$REPO_ROOT" vibe
aws s3 cp "$ARCHIVE" "s3://${RAW_BUCKET}/deployment/vibe-aws.tar.gz" --only-show-errors --region "$REGION"

echo "=== 4/6 Esperando a que el servidor esté disponible en SSM ==="
DEADLINE=$((SECONDS + 900))
until [[ "$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$SERVER_ID" \
    --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId | [0]' \
    --output text 2>/dev/null || true)" == "$SERVER_ID" ]]; do
  (( SECONDS < DEADLINE )) || die "El servidor no apareció Online en SSM en 15 minutos. Revisa EC2 y Systems Manager en AWS Academy."
  echo "Esperando al agente SSM del servidor..."
  sleep 10
done

echo "=== 5/6 Instalando K3s y desplegando VIBE ==="
REMOTE_SCRIPT="sudo -iu ec2-user bash -lc 'set -euo pipefail; aws s3 cp s3://${RAW_BUCKET}/deployment/vibe-aws.tar.gz ~/vibe-aws.tar.gz --region ${REGION}; tar -xzf ~/vibe-aws.tar.gz -C ~; cd ~/vibe_k8s/vibe; bash aws/cluster-init.sh ${RAW_BUCKET} ${HLS_BUCKET}'"
REQUEST_FILE="$(mktemp)"
jq -n \
  --arg id "$SERVER_ID" \
  --arg command "$REMOTE_SCRIPT" \
  '{InstanceIds:[$id],DocumentName:"AWS-RunShellScript",TimeoutSeconds:3600,Parameters:{commands:[$command],executionTimeout:["3600"]},Comment:"Despliegue VIBE AWS Academy"}' \
  > "$REQUEST_FILE"
COMMAND_ID="$(aws ssm send-command --cli-input-json "file://$REQUEST_FILE" --query Command.CommandId --output text --region "$REGION")" \
  || die "No se pudo iniciar SSM Run Command. Verifica permisos de LabRole para SSM."
echo "Comando SSM: $COMMAND_ID"

DEADLINE=$((SECONDS + 3900))
while true; do
  INVOCATION="$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$SERVER_ID" --output json --region "$REGION" 2>/dev/null || true)"
  STATUS="$(jq -r '.Status // "Pending"' <<< "$INVOCATION")"
  case "$STATUS" in
    Success) break ;;
    Failed|Cancelled|TimedOut|Cancelling)
      jq -r '"STDOUT:\n" + (.StandardOutputContent // "") + "\nSTDERR:\n" + (.StandardErrorContent // "")' <<< "$INVOCATION" >&2
      die "Falló la inicialización remota (estado SSM: $STATUS)."
      ;;
  esac
  (( SECONDS < DEADLINE )) || die "El comando SSM excedió el tiempo de espera. Revisa Run Command con ID $COMMAND_ID."
  echo "Inicialización en curso (SSM: $STATUS)..."
  sleep 15
done

echo "=== 6/6 Verificando la URL pública ==="
if ! curl -fsS --retry 30 --retry-delay 10 --retry-connrefused --retry-all-errors -o /dev/null "$ELB_URL"; then
  die "La aplicación fue instalada, pero el ELB aún no responde. Revisa los pods con kubectl mediante SSM."
fi

echo "Despliegue terminado."
echo "URL:        $ELB_URL"
echo "Bucket Raw: $RAW_BUCKET"
echo "Bucket HLS: $HLS_BUCKET"
echo "Guarda estos datos y las evidencias antes de que expire el sandbox."
