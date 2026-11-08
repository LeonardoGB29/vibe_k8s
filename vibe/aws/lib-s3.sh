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
