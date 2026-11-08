data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_security_group" "k3s_nodes" {
  filter {
    name   = "tag:Name"
    values = ["vibe-desarrollo-nodes"]
  }
}

module "postgres" {
  source = "../../modules/rds-postgres"

  identifier               = "vibe-staging-pg"
  environment              = "staging"
  vpc_id                   = data.aws_vpc.default.id
  subnet_ids               = data.aws_subnets.default.ids
  client_security_group_id = data.aws_security_group.k3s_nodes.id
  database_name            = "vibe"
  instance_class           = var.instance_class
  engine_version           = var.engine_version
  allocated_storage        = var.allocated_storage
  max_allocated_storage    = var.max_allocated_storage
  multi_az                 = false
  backup_retention_days    = 1
}
