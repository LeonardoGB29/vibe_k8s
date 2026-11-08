# El bucket del state lo crea aws/init-account.sh (o aws/deploy-aws.sh) con AWS CLI
# antes de ejecutar Terraform: no puede ser un recurso de este mismo state.
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
  default = "us-east-2"
}

data "aws_caller_identity" "current" {}

output "state_bucket" {
  description = "Nombre del bucket de state creado por aws/init-account.sh"
  value       = "vibe-tfstate-${data.aws_caller_identity.current.account_id}"
}
