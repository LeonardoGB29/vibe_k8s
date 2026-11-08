terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "random_password" "master" {
  length           = 24
  special          = false
  override_special = ""
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.identifier}-subnets"
  description = "Subredes para ${var.identifier}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name        = "${var.identifier}-subnets"
    Environment = var.environment
  }
}

resource "aws_security_group" "this" {
  name        = "${var.identifier}-db"
  description = "Acceso PostgreSQL desde los nodos de VIBE"
  vpc_id      = var.vpc_id
  egress      = []

  ingress {
    description     = "PostgreSQL desde VIBE"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.client_security_group_id]
  }

  tags = {
    Name        = "${var.identifier}-db"
    Environment = var.environment
  }
}

resource "aws_db_instance" "this" {
  identifier                   = var.identifier
  engine                       = "postgres"
  engine_version               = var.engine_version
  instance_class               = var.instance_class
  allocated_storage           = var.allocated_storage
  max_allocated_storage       = var.max_allocated_storage
  storage_type                = "gp2"
  storage_encrypted           = true
  db_name                     = var.database_name
  username                    = var.master_username
  password                    = random_password.master.result
  port                        = 5432
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.this.id]
  publicly_accessible         = false
  multi_az                    = var.multi_az
  backup_retention_period     = var.backup_retention_days
  auto_minor_version_upgrade = true
  deletion_protection         = false
  skip_final_snapshot         = true
  apply_immediately           = true

  tags = {
    Name        = var.identifier
    Project     = "vibe"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
