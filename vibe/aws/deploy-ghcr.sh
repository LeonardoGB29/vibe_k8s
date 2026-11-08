#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?Set IMAGE_TAG to the commit SHA published in GHCR}"
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

MANIFESTS="$(kubectl kustomize "k8s/overlays/${OVERLAY}")"
for service in frontend catalog-api upload-api stream-api worker; do
  image="${IMAGE_PREFIX}-${service}:${IMAGE_TAG}"
  sudo k3s ctr images pull "$image"
  MANIFESTS="$(printf '%s\n' "$MANIFESTS" | sed "s#image: vibe-${service}:dev#image: ${image}#g")"
done
printf '%s\n' "$MANIFESTS" | kubectl apply -f -

for service in frontend catalog-api upload-api stream-api worker; do
  kubectl -n "$NAMESPACE" rollout status "deployment/${service}" --timeout=240s
done

if [[ "$TARGET_ENVIRONMENT" == "desarrollo" ]]; then
  kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=180s
fi

echo "Entorno: $TARGET_ENVIRONMENT"
echo "Namespace: $NAMESPACE"
kubectl -n "$NAMESPACE" get pods -o wide
