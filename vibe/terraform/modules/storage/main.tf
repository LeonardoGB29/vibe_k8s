terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

variable "name_prefix" {
  description = "Prefijo de los buckets (ej. vibe-desarrollo)"
  type        = string
}

variable "force_destroy" {
  description = "Permite destruir buckets con audios dentro (true solo en entornos desechables)"
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

locals {
  buckets = toset(["raw", "hls"])
}

resource "aws_s3_bucket" "audio" {
  for_each = local.buckets

  bucket        = "${var.name_prefix}-audio-${each.key}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "audio" {
  for_each = aws_s3_bucket.audio

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audio" {
  for_each = aws_s3_bucket.audio

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 evita depender de permisos KMS que AWS Academy no concede.
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.audio

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "audio" {
  for_each = aws_s3_bucket.audio

  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.tls_only[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.audio]
}

output "raw_bucket" {
  value = aws_s3_bucket.audio["raw"].bucket
}

output "hls_bucket" {
  value = aws_s3_bucket.audio["hls"].bucket
}
