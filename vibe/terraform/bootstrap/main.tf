# AWS Academy deniega s3:GetBucketObjectLockConfiguration. El proveedor AWS
# de Terraform consulta esa operación al gestionar aws_s3_bucket; por eso el
# script de despliegue crea/configura el bucket del state mediante AWS CLI.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "vibe"
      ManagedBy = "terraform"
      Component = "tfstate"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

data "aws_caller_identity" "current" {}

output "state_bucket" {
  description = "Nombre del bucket creado/configurado por aws/deploy-sandbox.sh"
  value       = "vibe-tfstate-${data.aws_caller_identity.current.account_id}"
}
