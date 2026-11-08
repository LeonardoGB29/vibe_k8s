#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?Set IMAGE_TAG to the GHCR tag, e.g. sha-<40-char commit SHA>}"
REGISTRY_OWNER="${REGISTRY_OWNER:?Set REGISTRY_OWNER to the lowercase GitHub owner}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-desarrollo}"
REPO="${REPO:-vibe_k8s}"
IMAGE_PREFIX="ghcr.io/${REGISTRY_OWNER}/${REPO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$TARGET_ENVIRONMENT" in
  desarrollo)
    OVERLAY="desarrollo"
    NAMESPACE="vibe"
    ;;
  staging)
    OVERLAY="staging"
    NAMESPACE="vibe-staging"
    ;;
  produccion)
    OVERLAY="produccion"
    NAMESPACE="vibe-produccion"
    ;;
  *)
    echo "ERROR: TARGET_ENVIRONMENT debe ser desarrollo, staging o produccion." >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"

# Crear el namespace antes de desplegar recursos. Staging y producción usan
# Secretos independientes: DATABASE_URL debe ser una URL de RDS con un usuario
# de aplicación de permisos restringidos, aprovisionado fuera del repositorio.
kubectl apply -f "k8s/overlays/${OVERLAY}/namespace.yaml"
if ! kubectl -n "$NAMESPACE" get secret vibe-secrets >/dev/null 2>&1; then
  echo "ERROR: falta el Secret vibe-secrets en namespace $NAMESPACE." >&2
  if [[ "$TARGET_ENVIRONMENT" != "desarrollo" ]]; then
    echo "Debe contener DATABASE_URL del RDS de $TARGET_ENVIRONMENT y las credenciales AWS/S3 de la aplicación." >&2
  fi
  exit 1
fi
if ! kubectl -n "$NAMESPACE" get secret vibe-secrets -o jsonpath='{.data.DATABASE_URL}' | grep -q .; then
  echo "ERROR: el Secret vibe-secrets de $NAMESPACE no contiene DATABASE_URL." >&2
  exit 1
fi

# Los entornos comparten los buckets creados por desarrollo. Copiar únicamente
# la configuración no secreta de S3/Redis; las credenciales y DATABASE_URL no
# se copian entre entornos.
if [[ "$TARGET_ENVIRONMENT" != "desarrollo" ]] && ! kubectl -n "$NAMESPACE" get configmap vibe-config >/dev/null 2>&1; then
  if ! kubectl -n vibe get configmap vibe-config -o json | jq --arg namespace "$NAMESPACE" '
    del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields)
    | .metadata.namespace = $namespace
  ' | kubectl apply -f -; then
    echo "ERROR: falta vibe-config en $NAMESPACE y no se pudo copiar desde vibe." >&2
    exit 1
  fi
fi

SERVICES=(frontend catalog-api upload-api stream-api worker)
for service in "${SERVICES[@]}"; do
  # Falla pronto y con claro mensaje si el nodo no puede bajar la imagen de GHCR
  # (tag inexistente o paquete privado).
  if ! sudo k3s ctr images pull "${IMAGE_PREFIX}-${service}:${IMAGE_TAG}"; then
    echo "ERROR: el nodo no pudo descargar ${IMAGE_PREFIX}-${service}:${IMAGE_TAG} de GHCR." >&2
    echo "Comprueba que el tag existe y que el paquete es publico (Package settings > Change visibility)." >&2
    exit 1
  fi
done

# Overlay temporal que apunta al del entorno y fija las imagenes con el
# transformador `images:` de kustomize (en vez de sed sobre el YAML renderizado).
DEPLOY_DIR="$(mktemp -d "k8s/overlays/.deploy.XXXXXX")"
APPLIED=0

rollback() {
  echo "ERROR: el despliegue fallo; restaurando la revision anterior de cada Deployment..." >&2
  for service in "${SERVICES[@]}"; do
    kubectl -n "$NAMESPACE" rollout undo "deployment/${service}" || true
  done
  for service in "${SERVICES[@]}"; do
    kubectl -n "$NAMESPACE" rollout status "deployment/${service}" --timeout=120s || true
  done
  kubectl -n "$NAMESPACE" get pods -o wide || true
}

cleanup() {
  local rc=$?
  rm -rf "$DEPLOY_DIR"
  if (( rc != 0 && APPLIED == 1 )); then
    rollback
  fi
  exit "$rc"
}
trap cleanup EXIT

# Comprobacion de salud desde dentro del cluster (ClusterIP): frontend y catalogo con acceso a la base.
health_check() {
  local frontend_ip catalog_ip
  frontend_ip="$(kubectl -n "$NAMESPACE" get svc frontend -o jsonpath='{.spec.clusterIP}')"
  catalog_ip="$(kubectl -n "$NAMESPACE" get svc catalog-api -o jsonpath='{.spec.clusterIP}')"
  curl -fsS --retry 10 --retry-delay 3 --retry-connrefused --max-time 10 -o /dev/null \
    -w "frontend /healthz -> %{http_code}\n" "http://${frontend_ip}/healthz" || return 1
  for path in /api/stats /api/tracks; do
    curl -fsS --retry 10 --retry-delay 3 --retry-connrefused --max-time 10 -o /dev/null \
      -w "catalog-api ${path} -> %{http_code}\n" "http://${catalog_ip}:8000${path}" || return 1
  done
}

{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  echo "  - ../${OVERLAY}"
  echo "images:"
  for service in "${SERVICES[@]}"; do
    echo "  - name: vibe-${service}"
    echo "    newName: ${IMAGE_PREFIX}-${service}"
    echo "    newTag: ${IMAGE_TAG}"
  done
} > "$DEPLOY_DIR/kustomization.yaml"
kubectl kustomize "$DEPLOY_DIR" | kubectl apply -f -
APPLIED=1

for service in "${SERVICES[@]}"; do
  kubectl -n "$NAMESPACE" rollout status "deployment/${service}" --timeout=240s
done

if [[ "$TARGET_ENVIRONMENT" == "desarrollo" ]]; then
  kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=180s
fi

health_check

echo "Entorno: $TARGET_ENVIRONMENT"
echo "Namespace: $NAMESPACE"
echo "Imagen: ${IMAGE_TAG}"
kubectl -n "$NAMESPACE" get pods -o wide
