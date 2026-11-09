#!/usr/bin/env bash
# Funciones compartidas por deploy-aws.sh e init-account.sh (se usan con `source`).
# Requiere: aws y la variable REGION.

# Crea (si no existe) un bucket privado, cifrado, versionado y solo accesible por TLS.
ensure_s3_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
    echo "Reutilizando bucket existente: $bucket"
  else
    echo "Creando bucket: $bucket"
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
    else
      # Fuera de us-east-1 la region debe indicarse como LocationConstraint.
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
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

  # Politica inline (sin archivo temporal ni jq): rechaza cualquier acceso sin TLS.
  local policy
  policy="$(printf '{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}' "$bucket" "$bucket")"
  aws s3api put-bucket-policy --bucket "$bucket" --policy "$policy" --region "$REGION"
}

# Terraform (proveedor AWS) no entiende los perfiles creados con `aws login`:
# exporta las credenciales temporales del perfil activo a variables de entorno.
export_aws_credentials() {
  local creds
  if creds="$(aws configure export-credentials --format env 2>/dev/null)"; then
    eval "$creds"
  fi
}

# --- Imagenes publicadas en GHCR (acceso anonimo: los paquetes del repositorio son publicos) ---
GHCR_SERVICES=(frontend catalog-api upload-api stream-api worker)

# ghcr_image_exists <owner> <repo> <servicio> <tag>
ghcr_image_exists() {
  local token code
  token="$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:$1/$2-$3:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || return 1
  [[ -n "$token" ]] || return 1
  code="$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/$1/$2-$3/manifests/$4")"
  [[ "$code" == 200 ]]
}

ghcr_all_images_exist() {  # <owner> <repo> <tag>
  local s
  for s in "${GHCR_SERVICES[@]}"; do ghcr_image_exists "$1" "$2" "$s" "$3" || return 1; done
}

# resolve_image_tag: fija REGISTRY_OWNER, REGISTRY_REPO e IMAGE_TAG (sha-<commit>).
# Usa VIBE_IMAGE_TAG si se indica; si no, el commit mas reciente de HEAD cuyas 5 imagenes
# existen en GHCR (el CI las publica en cada push a main/develop). Requiere REPO_ROOT.
resolve_image_tag() {
  local url sha
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  REGISTRY_REPO="${REGISTRY_REPO:-$(basename "${url:-x}" .git)}"
  REGISTRY_OWNER="${REGISTRY_OWNER:-$(sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#' <<< "$url" | tr '[:upper:]' '[:lower:]')}"
  [[ -n "$REGISTRY_OWNER" && -n "$REGISTRY_REPO" ]] || { echo "ERROR: no pude deducir owner/repo de 'git remote origin'. Define REGISTRY_OWNER y REGISTRY_REPO." >&2; return 1; }

  if [[ -n "${VIBE_IMAGE_TAG:-}" ]]; then
    IMAGE_TAG="$VIBE_IMAGE_TAG"
    ghcr_all_images_exist "$REGISTRY_OWNER" "$REGISTRY_REPO" "$IMAGE_TAG" \
      || { echo "ERROR: faltan imagenes ${IMAGE_TAG} en ghcr.io/${REGISTRY_OWNER}/${REGISTRY_REPO}-*" >&2; return 1; }
    return 0
  fi
  for sha in $(git -C "$REPO_ROOT" rev-list -n 40 HEAD); do
    if ghcr_all_images_exist "$REGISTRY_OWNER" "$REGISTRY_REPO" "sha-$sha"; then
      IMAGE_TAG="sha-$sha"
      [[ "$sha" == "$(git -C "$REPO_ROOT" rev-parse HEAD)" ]] || \
        echo "AVISO: HEAD no tiene imagenes publicadas; se usan las del commit ${sha:0:7} (el mas reciente con CI completo)." >&2
      return 0
    fi
  done
  echo "ERROR: ninguno de los ultimos 40 commits tiene sus 5 imagenes en GHCR. Haz push y espera al job image-publish del CI, o indica VIBE_IMAGE_TAG=sha-<commit>." >&2
  return 1
}
