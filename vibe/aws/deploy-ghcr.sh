#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?Set IMAGE_TAG to the commit SHA published in GHCR}"
REGISTRY_OWNER="${REGISTRY_OWNER:?Set REGISTRY_OWNER to the lowercase GitHub owner}"
REPO="${REPO:-vibe_k8s}"
IMAGE_PREFIX="ghcr.io/${REGISTRY_OWNER}/${REPO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
for service in frontend catalog-api upload-api stream-api worker; do
  image="${IMAGE_PREFIX}-${service}:${IMAGE_TAG}"
  sudo k3s ctr images pull "$image"
  kubectl -n vibe set image "deployment/${service}" "${service}=${image}"
done

for service in frontend catalog-api upload-api stream-api worker; do
  kubectl -n vibe rollout status "deployment/${service}" --timeout=240s
done
