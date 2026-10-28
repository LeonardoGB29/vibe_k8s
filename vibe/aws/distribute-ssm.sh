#!/bin/bash
# Importa imágenes en los agentes sin copiar claves SSH al servidor.
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
IP_CSV=$(kubectl get nodes -o json | jq -r '[.items[] | select(.metadata.name != "k3s-server") | .status.addresses[] | select(.type == "InternalIP") | .address] | join(",")')
IDS_JSON=$(aws ec2 describe-instances --filters "Name=private-ip-address,Values=$IP_CSV" Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output json)
[[ $(jq 'length' <<< "$IDS_JSON") == 3 ]] || { echo "No se encontraron exactamente tres EC2 agentes" >&2; exit 1; }
IDS_CSV=$(jq -r 'join(",")' <<< "$IDS_JSON")
ONLINE=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$IDS_CSV" --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output json)
[[ $(jq 'length' <<< "$ONLINE") == 3 ]] || { echo "Los tres agentes deben estar Online en SSM" >&2; exit 1; }
WORK_DIR=$(mktemp -d /tmp/vibe-ssm.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# Revisar cada agente antes de empezar una construcción larga en el servidor.
PREFLIGHT_SCRIPT="free_mib=\$(df -Pm / | awk 'NR == 2 {print \$4}'); echo \"Espacio libre en \$(hostname): \${free_mib} MiB\"; if [ \"\$free_mib\" -lt ${VIBE_MIN_AGENT_MIB:-5000} ]; then echo \"Espacio insuficiente en \$(hostname): se requieren ${VIBE_MIN_AGENT_MIB:-5000} MiB libres\" >&2; exit 1; fi"
jq -n --arg script "$PREFLIGHT_SCRIPT" '{commands:[$script]}' > "$WORK_DIR/preflight.json"
PREFLIGHT_ID=$(aws ssm send-command --document-name AWS-RunShellScript \
    --instance-ids $(jq -r '.[]' <<< "$ONLINE") \
    --parameters "file://$WORK_DIR/preflight.json" \
    --query Command.CommandId --output text)
PREFLIGHT_DEADLINE=$((SECONDS + 180))
while true; do
    PREFLIGHT=$(aws ssm list-command-invocations --command-id "$PREFLIGHT_ID" --details --output json)
    if jq -e '.CommandInvocations | any(.Status == "Failed" or .Status == "Cancelled" or .Status == "TimedOut")' <<< "$PREFLIGHT" >/dev/null; then
        echo "No pasó la revisión de espacio de los agentes. Libera espacio o ajusta el volumen y vuelve a desplegar." >&2
        jq -r '.CommandInvocations[] | [.InstanceId, .Status, (.CommandPlugins[0].Output // "")] | @tsv' <<< "$PREFLIGHT" >&2
        exit 1
    fi
    if jq -e '.CommandInvocations | length == 3 and all(.Status == "Success")' <<< "$PREFLIGHT" >/dev/null; then
        jq -r '.CommandInvocations[] | .CommandPlugins[0].Output // empty' <<< "$PREFLIGHT"
        break
    fi
    if (( SECONDS >= PREFLIGHT_DEADLINE )); then
        echo "Se agotó el tiempo de la revisión de espacio SSM ($PREFLIGHT_ID)." >&2
        exit 1
    fi
    sleep 5
done
[[ "${1:-}" != --check ]] || exit 0
ARCHIVE="${1:?Indica el archivo de imágenes}"
: "${IMAGE_BUCKET:?Indica IMAGE_BUCKET}"
OBJECT_KEY="deployment/images/$(sha256sum "$ARCHIVE" | cut -d ' ' -f1).tar"
aws s3 cp "$ARCHIVE" "s3://$IMAGE_BUCKET/$OBJECT_KEY" --only-show-errors
DOWNLOAD_URL=$(aws s3 presign "s3://$IMAGE_BUCKET/$OBJECT_KEY" --expires-in 1800)
# Mantener la URL firmada fuera de la salida y de los argumentos de procesos.
export VIBE_DOWNLOAD_URL="$DOWNLOAD_URL"
python3 - "$WORK_DIR/parameters.json" <<'PY'
import json, os, shlex, sys
url = shlex.quote(os.environ['VIBE_DOWNLOAD_URL'])
script = '\n'.join([
    'set -eu',
    'work_dir=$(mktemp -d /tmp/vibe-import.XXXXXX)',
    'trap \'rm -rf "$work_dir"\' EXIT',
    f'free_mib=$(df -Pm / | awk \'NR == 2 {{print $4}}\'); echo "Espacio antes de importar en $(hostname): $free_mib MiB"; if [ "$free_mib" -lt {os.environ.get("VIBE_MIN_AGENT_MIB", "5000")} ]; then echo "Espacio insuficiente en $(hostname); se requieren {os.environ.get("VIBE_MIN_AGENT_MIB", "5000")} MiB libres" >&2; exit 1; fi',
    f'curl -fsS --retry 3 --max-time 900 {url} -o "$work_dir/images.tar"',
    'free_mib=$(df -Pm / | awk \'NR == 2 {print $4}\'); archive_mib=$(du -m "$work_dir/images.tar" | awk \'{print $1}\'); required_mib=$((archive_mib + 1200)); echo "Espacio libre en $(hostname) después de descargar: $free_mib MiB; reserva estimada para importar: $required_mib MiB"; if [ "$free_mib" -lt "$required_mib" ]; then echo "Espacio insuficiente en $(hostname); libera espacio antes de importar imágenes" >&2; exit 1; fi',
    'k3s ctr images import "$work_dir/images.tar"',
    'for name in frontend catalog-api upload-api stream-api worker; do',
    '  k3s ctr images ls -q | grep -Fx "docker.io/library/vibe-$name:dev" >/dev/null',
    'done',
])
with open(sys.argv[1], 'w') as f:
    json.dump({'commands': [script], 'executionTimeout': ['1200']}, f)
os.chmod(sys.argv[1], 0o600)
PY
unset VIBE_DOWNLOAD_URL DOWNLOAD_URL
COMMAND_ID=$(aws ssm send-command --document-name AWS-RunShellScript --targets "Key=InstanceIds,Values=$IDS_CSV" --parameters "file://$WORK_DIR/parameters.json" --query Command.CommandId --output text)
echo "Importación enviada a los tres agentes. Comando SSM: $COMMAND_ID"
DEADLINE=$((SECONDS + 1200))
while true; do
    INVOCATIONS=$(aws ssm list-command-invocations --command-id "$COMMAND_ID" --output json)
    if jq -e '.CommandInvocations | any(.Status == "Failed" or .Status == "Cancelled" or .Status == "TimedOut")' <<< "$INVOCATIONS" >/dev/null; then
        echo "Falló la importación; revisa el comando $COMMAND_ID en SSM Run Command" >&2
        exit 1
    fi
    if jq -e '.CommandInvocations | length == 3 and all(.Status == "Success")' <<< "$INVOCATIONS" >/dev/null; then
        break
    fi
    if (( SECONDS >= DEADLINE )); then
        echo "La importación superó 20 minutos; revisa $COMMAND_ID" >&2
        exit 1
    fi
    sleep 5
done
