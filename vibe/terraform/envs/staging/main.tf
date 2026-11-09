locals {
  name = "vibe-${var.environment}"
}

# Staging tiene su propio clúster k3s, balanceador, security groups, rol de nodos,
# buckets y monitoreo (mismos módulos que desarrollo, con prefijo vibe-staging).
# La VPC predeterminada sí se comparte; el aislamiento es por security group.
module "network" {
  source = "../../modules/network"

  name_prefix = local.name
}

module "storage" {
  source = "../../modules/storage"

  name_prefix = local.name
}

module "node_iam" {
  source = "../../modules/node-iam"

  name_prefix     = local.name
  bucket_names    = [module.storage.raw_bucket, module.storage.hls_bucket]
  token_parameter = "/${local.name}/k3s-token"
  # La crea aws/deploy-aws.sh con la URL del RDS de este entorno.
  extra_parameters = ["/${local.name}/database-url"]
  # Permisos del Cluster Autoscaler (escalado automatico de agentes).
  cluster_autoscaler = true
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
  autoscaling_enabled     = true
  agent_max               = var.agent_max
  instance_profile        = module.node_iam.instance_profile_name
  key_name                = var.key_name
  ami_id                  = var.ami_id
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix  = local.name
  region       = var.region
  elb_name     = module.cluster.elb_name
  instance_ids = module.cluster.instance_ids
  alert_email  = var.alert_email
  # Los agentes los crea el Auto Scaling Group: se vigilan como grupo, no instancia a instancia.
  asg_name     = module.cluster.agent_asg_name != null ? module.cluster.agent_asg_name : ""
  asg_min_size = var.agent_count
}

# RDS: solo acepta conexiones desde los nodos de ESTE entorno.
module "postgres" {
  source = "../../modules/rds-postgres"

  identifier               = "vibe-staging-pg"
  environment              = "staging"
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.subnet_ids
  client_security_group_id = module.network.nodes_security_group_id
  database_name            = "vibe"
  instance_class           = var.instance_class
  engine_version           = var.engine_version
  allocated_storage        = var.allocated_storage
  max_allocated_storage    = var.max_allocated_storage
  multi_az                 = false
  backup_retention_days    = 1
}
