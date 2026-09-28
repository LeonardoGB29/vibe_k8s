#!/bin/bash
# ==============================================================================
# VIBE - AWS Teardown Script
# Vacia buckets de S3 y elimina el stack CloudFormation
# ==============================================================================
set -euo pipefail

STACK_NAME="vibe-k3s"
REGION="us-east-1"

echo "=========================================================="
echo " 🧹 Eliminando recursos de VIBE en AWS"
echo "=========================================================="

# 1. Obtener nombres de buckets del stack
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].Outputs" 2>/dev/null || true)

if [ -n "$OUTPUTS" ] && [ "$OUTPUTS" != "null" ]; then
    RAW_BUCKET=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="RawBucketName") | .OutputValue' 2>/dev/null || true)
    HLS_BUCKET=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="HlsBucketName") | .OutputValue' 2>/dev/null || true)

    if [ -n "$RAW_BUCKET" ] && [ "$RAW_BUCKET" != "null" ]; then
        echo "Vaciando bucket S3: $RAW_BUCKET..."
        aws s3 rm "s3://$RAW_BUCKET" --recursive 2>/dev/null || true
    fi

    if [ -n "$HLS_BUCKET" ] && [ "$HLS_BUCKET" != "null" ]; then
        echo "Vaciando bucket S3: $HLS_BUCKET..."
        aws s3 rm "s3://$HLS_BUCKET" --recursive 2>/dev/null || true
    fi
fi

# 2. Eliminar el stack
echo "Eliminando stack CloudFormation '$STACK_NAME'..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "Esperando que el stack se elimine por completo..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" || true

echo "✅ Todos los recursos en AWS han sido eliminados correctamente."
