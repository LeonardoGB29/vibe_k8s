terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

# Los buckets se crean/configuran desde aws/deploy-aws.sh con AWS CLI.
# Se hace así para que el mismo script cree el bucket del state antes de que
# Terraform exista; el proveedor AWS no gestiona estos buckets.
variable "name_prefix" {
  description = "Prefijo de los buckets (ej. vibe-desarrollo)"
  type        = string
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

output "raw_bucket" {
  value = "${var.name_prefix}-audio-raw-${local.account_id}"
}

output "hls_bucket" {
  value = "${var.name_prefix}-audio-hls-${local.account_id}"
}
