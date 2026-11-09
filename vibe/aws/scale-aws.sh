#!/usr/bin/env bash
# Escalado horizontal de un entorno: cambia el numero de agentes k3s (nodos que se unen al
# servidor). Los pods nuevos se reparten solos porque las imagenes se descargan de GHCR.
#   bash aws/scale-aws.sh <desarrollo|staging|produccion> <agentes 0-6>
# Ejemplos:  bash aws/scale-aws.sh staging 3     # sube a 1 servidor + 3 agentes para una prueba de carga
#            bash aws/scale-aws.sh staging 0     # vuelve a un solo nodo al terminar
# Cada agente es una t3.small (~0,7 USD/dia con su IPv4 y disco). Al reducir, primero vacia (drain) los nodos
# que sobran para que Kubernetes reprograme sus pods sin cortes bruscos.
#
# Dos modos, segun el entorno (se detecta solo):
#  - Agentes fijos (desarrollo, produccion): el numero es el de instancias k3s-agent-N.
#  - Autoescalado (staging, con Auto Scaling Group + Cluster Autoscaler): el numero es el MINIMO del grupo.
#    Subirlo crea agentes ya; bajarlo vacia y termina los sobrantes. Aunque lo dejes en 0, el Cluster
#    Autoscaler puede volver a añadir agentes (hasta agent_max) si hay pods sin sitio.
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

# Autoescalado: el output agent_asg_name solo existe (y no es null) cuando el entorno usa Auto Scaling Group.
ASG_NAME="$( { terraform output -json agent_asg_name 2>/dev/null || true; } | jq -r '. // empty' 2>/dev/null | tr -d '\r' || true)"

# Ids de las instancias vivas del ASG, una por linea.
asg_instances() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --output json \
    | jq -r '.AutoScalingGroups[0].Instances[] | select(.LifecycleState != "Terminating" and .LifecycleState != "Terminated") | .InstanceId' \
    | tr -d '\r'
}

ASG_IDS=()
if [[ -n "$ASG_NAME" ]]; then
  MODE="autoescalado, ASG $ASG_NAME"
  mapfile -t ASG_IDS < <(asg_instances)
  CURRENT="${#ASG_IDS[@]}"
  ASG_MAX="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].MaxSize' --output text | tr -d '[:space:]')"
  (( AGENTS <= ASG_MAX )) || die "El maximo del grupo es $ASG_MAX agentes (agent_max). Subelo en terraform/envs/$ENVIRONMENT/agents.auto.tfvars (revisa antes tu cuota de vCPU) o pide menos agentes."
else
  MODE="agentes fijos"
  CURRENT="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vibe-${ENVIRONMENT}-k3s-agent-*" 'Name=instance-state-name,Values=pending,running,stopped,stopping' --query 'length(Reservations[].Instances[])' --output text | tr -d '[:space:]')"
fi

echo "Entorno:  $ENVIRONMENT   [$MODE]"
if [[ -n "$ASG_NAME" ]]; then
  echo "Agentes:  $CURRENT -> minimo $AGENTS (el Cluster Autoscaler puede llegar a $ASG_MAX)   (nodos con el minimo: $((AGENTS + 1)), $(((AGENTS + 1) * 2)) vCPU)"
else
  echo "Agentes:  $CURRENT -> $AGENTS   (nodos totales: $((AGENTS + 1)), $(((AGENTS + 1) * 2)) vCPU)"
fi
echo "Costo por agente: ~0,7 USD/dia (t3.small + IPv4 + disco). Comprueba tu cuota de vCPU de EC2 si subes."
read -r -p "Escribe escalar para continuar: " CONFIRM
[[ "$CONFIRM" == "escalar" ]] || die "Cancelado."

apply_terraform() {
  printf 'agent_count = %s\n' "$AGENTS" > agents.auto.tfvars   # persiste el valor para futuros apply locales (ignorado por git)
  terraform apply -auto-approve -input=false -var="region=$REGION" -var="alert_email=${VIBE_ALERT_EMAIL:-}"
}

drain_node() {  # $1 = nombre del nodo; si no se puede vaciar, Kubernetes reprograma sus pods al desaparecer
  echo "Vaciando $1 ..."
  ssm_run "$SERVER_ID" "kubectl drain $1 --ignore-daemonsets --delete-emptydir-data --force --timeout=180s" \
    || echo "AVISO: no pude vaciar $1; Kubernetes reprogramara sus pods cuando desaparezca."
}

if [[ -n "$ASG_NAME" ]]; then
  # Primero el minimo nuevo: al subirlo AWS crea los agentes que faltan; al bajarlo evita que la
  # terminacion de abajo choque con el minimo anterior.
  apply_terraform
  if (( AGENTS < CURRENT )); then
    # Se retiran los ultimos de la lista: se vacian, se terminan restando capacidad y se borra su nodo.
    for id in "${ASG_IDS[@]:AGENTS}"; do
      drain_node "k3s-agent-$id"
      aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" --should-decrement-desired-capacity >/dev/null
      ssm_run "$SERVER_ID" "kubectl delete node k3s-agent-$id --ignore-not-found" || true
    done
  fi
else
  # Reducir: vaciar primero los agentes que sobran (los de mayor numero).
  if (( AGENTS < CURRENT )); then
    for ((n = CURRENT; n > AGENTS; n--)); do drain_node "k3s-agent-$n"; done
  fi
  apply_terraform
  if (( AGENTS < CURRENT )); then
    for ((n = CURRENT; n > AGENTS; n--)); do ssm_run "$SERVER_ID" "kubectl delete node k3s-agent-$n --ignore-not-found" || true; done
  fi
fi

# Nodos Ready en el clúster. Con autoescalado puede haber mas que el minimo (los añadio el Cluster
# Autoscaler): basta con llegar al minimo. Con agentes fijos tiene que ser exactamente el pedido.
ready_nodes() { ssm_run "$SERVER_ID" "kubectl get nodes --no-headers | grep -c ' Ready'" 2>/dev/null | tr -d '[:space:]'; }
nodes_ok() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "$ASG_NAME" ]]; then (( n >= AGENTS + 1 )); else (( n == AGENTS + 1 )); fi
}

echo "Esperando a que el clúster tenga $((AGENTS + 1)) nodos Ready ..."
DEADLINE=$((SECONDS + 600))
until nodes_ok "$(ready_nodes || true)"; do
  (( SECONDS < DEADLINE )) || die "Los nodos no llegaron a Ready en 10 minutos (revisa: kubectl get nodes)."
  sleep 15
done
ssm_run "$SERVER_ID" "kubectl get nodes -o wide; echo; kubectl get pods -A -o wide | grep -v kube-system | head -40"
echo "Listo. Los pods se reparten solos; HPA y KEDA usan la capacidad nueva."
