provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "vibe"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name = "vibe-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name
}

module "storage" {
  source = "../../modules/storage"

  name_prefix = local.name
  # Entorno desechable de pruebas: permite `terraform destroy` con audios dentro.
  force_destroy = true
}

module "cluster" {
  source = "../../modules/k3s-cluster"

  name_prefix             = local.name
  region                  = var.region
  subnet_ids              = module.network.subnet_ids
  nodes_security_group_id = module.network.nodes_security_group_id
  lb_security_group_id    = module.network.lb_security_group_id
  k3s_version             = var.k3s_version
  server_instance_type    = var.server_instance_type
  agent_instance_type     = var.agent_instance_type
  agent_count             = var.agent_count
  instance_profile        = var.instance_profile
  key_name                = var.key_name
  ami_id                  = var.ami_id
}
