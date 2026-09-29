#!/usr/bin/env bash
# Rolling update local del frontend; restaura la imagen original al terminar.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VERSION="${1:-v2}"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "Versión inválida"
require_cmds kubectl docker kind curl
require_cluster
kind get clusters | grep -qx vibe || die "No existe el cluster kind vibe"

ORIGINAL_IMAGE="$(kubectl -n "$NS" get deployment/frontend -o jsonpath='{.spec.template.spec.containers[?(@.name=="frontend")].image}')"
[[ -n "$ORIGINAL_IMAGE" ]] || die "No se pudo obtener la imagen actual"
TARGET_IMAGE="vibe-frontend:$VERSION"
docker image inspect vibe-frontend:dev >/dev/null 2>&1 || die "Falta vibe-frontend:dev; ejecuta make build-ms"
docker tag vibe-frontend:dev "$TARGET_IMAGE"
kind load docker-image "$TARGET_IMAGE" --name vibe >/dev/null

RESTORED=0
cleanup() {
  stop_probe
  if (( RESTORED == 0 )); then
    kubectl -n "$NS" set image deployment/frontend "frontend=$ORIGINAL_IMAGE" >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status deployment/frontend --timeout=180s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
start_probe "rolling-$VERSION" "$BASE_URL/healthz" 0.2

echo "[$(now)] Rolling update: $ORIGINAL_IMAGE -> $TARGET_IMAGE"
kubectl -n "$NS" set image deployment/frontend "frontend=$TARGET_IMAGE" >/dev/null
kubectl -n "$NS" rollout status deployment/frontend --timeout=180s
sleep 10
echo "[$(now)] Restaurando $ORIGINAL_IMAGE"
kubectl -n "$NS" set image deployment/frontend "frontend=$ORIGINAL_IMAGE" >/dev/null
kubectl -n "$NS" rollout status deployment/frontend --timeout=180s
RESTORED=1

stop_probe
trap - EXIT
echo "Evidencia: $PROBE_FILE"
(( PROBE_ERRORS == 0 )) || die "El rolling update produjo $PROBE_ERRORS errores HTTP"
echo "OK: rolling update con cero errores"
