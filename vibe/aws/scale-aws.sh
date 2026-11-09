#!/usr/bin/env bash
# Escalado horizontal de un entorno: cambia el numero de agentes k3s (nodos que se unen al
# servidor). Los pods nuevos se reparten solos porque las imagenes se descargan de GHCR.
#   bash aws/scale-aws.sh <desarrollo|staging|produccion> <agentes 0-6>
# Ejemplos:  bash aws/scale-aws.sh staging 3     # sube a 1 servidor + 3 agentes para una prueba de carga
#            bash aws/scale-aws.sh staging 0     # vuelve a un solo nodo al terminar
# Cada agente es una t3.small (~0,7 USD/dia con su IPv4 y disco). Al reducir, primero vacia (drain) los nodos
# que sobran para que Kubernetes reprograme sus pods sin cortes bruscos.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-2}}"
# shellcheck source=lib-s3.sh
source "$SCRIPT_DIR/lib-s3.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
ENVIRONMENT="${1:-}"; AGENTS="${2:-}"
case "$ENVIRONMENT" in desarrollo|staging|produccion) ;; *) die "Uso: bash aws/scale-aws.sh <desarrollo|staging|produccion> <agentes 0-6>" ;; esac
[[ "$AGENTS" =~ ^[0-6]$ ]] || die "El numero de agentes debe estar entre 0 y 6."
for tool in aws terraform jq; do command -v "$tool" >/dev/null 2>&1 || die "No encuentro '$tool'."; done

export AWS_DEFAULT_REGION="$REGION"
aws sts get-caller-identity >/dev/null || die "AWS CLI sin credenciales activas (aws login / AWS_PROFILE)."
export_aws_credentials
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ENV_DIR="$VIBE_DIR/terraform/envs/$ENVIRONMENT"

# Ejecuta un comando como ec2-user en el servidor por SSM y muestra su salida.
ssm_run() {
  local id="$1" cmd="$2" cid status i
  cid="$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg c "sudo -iu ec2-user bash -lc $(printf '%q' "export KUBECONFIG=~/.kube/config; $cmd")" '{commands:[$c]}')" \
    --query Command.CommandId --output text)"
  for i in $(seq 1 60); do
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text; return 0 ;;
      Failed|Cancelled|TimedOut) aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query '[StandardOutputContent,StandardErrorContent]' --output text >&2; return 1 ;;
    esac
    sleep 3
  done
  return 1
}

cd "$ENV_DIR"
printf 'bucket = "%s"\n' "vibe-tfstate-${ACCOUNT_ID}" > backend.hcl
terraform init -backend-config=backend.hcl -lockfile=readonly -input=false >/dev/null
SERVER_ID="$(terraform output -raw server_instance_id 2>/dev/null)" || die "El entorno $ENVIRONMENT no esta desplegado (usa aws/deploy-aws.sh $ENVIRONMENT)."
CURRENT="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vibe-${ENVIRONMENT}-k3s-agent-*" 'Name=instance-state-name,Values=pending,running,stopped,stopping' --query 'length(Reservations[].Instances[])' --output text)"

echo "Entorno:  $ENVIRONMENT"
echo "Agentes:  $CURRENT -> $AGENTS   (nodos totales: $((AGENTS + 1)), $(((AGENTS + 1) * 2)) vCPU)"
echo "Costo por agente: ~0,7 USD/dia (t3.small + IPv4 + disco). Comprueba tu cuota de vCPU de EC2 si subes."
read -r -p "Escribe escalar para continuar: " CONFIRM
[[ "$CONFIRM" == "escalar" ]] || die "Cancelado."

# Reducir: vaciar primero los agentes que sobran (los de mayor numero).
if (( AGENTS < CURRENT )); then
  for ((n = CURRENT; n > AGENTS; n--)); do
    echo "Vaciando k3s-agent-$n ..."
    ssm_run "$SERVER_ID" "kubectl drain k3s-agent-$n --ignore-daemonsets --delete-emptydir-data --force --timeout=180s" || echo "AVISO: no pude vaciar k3s-agent-$n; Kubernetes reprogramara sus pods al detenerse."
  done
fi

printf 'agent_count = %s\n' "$AGENTS" > agents.auto.tfvars   # persiste el valor para futuros apply locales (ignorado por git)
terraform apply -auto-approve -input=false -var="region=$REGION" -var="alert_email=${VIBE_ALERT_EMAIL:-}"

if (( AGENTS < CURRENT )); then
  for ((n = CURRENT; n > AGENTS; n--)); do ssm_run "$SERVER_ID" "kubectl delete node k3s-agent-$n --ignore-not-found" || true; done
fi

echo "Esperando a que el clúster tenga $((AGENTS + 1)) nodos Ready ..."
DEADLINE=$((SECONDS + 600))
until [[ "$(ssm_run "$SERVER_ID" "kubectl get nodes --no-headers | grep -c ' Ready'" 2>/dev/null | tr -d '[:space:]')" == "$((AGENTS + 1))" ]]; do
  (( SECONDS < DEADLINE )) || die "Los nodos no llegaron a Ready en 10 minutos (revisa: kubectl get nodes)."
  sleep 15
done
ssm_run "$SERVER_ID" "kubectl get nodes -o wide; echo; kubectl get pods -A -o wide | grep -v kube-system | head -40"
echo "Listo. Los pods se reparten solos; HPA y KEDA usan la capacidad nueva."
