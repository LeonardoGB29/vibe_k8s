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

variable "name_prefix" {
  description = "Prefijo de los recursos (ej. vibe-desarrollo)"
  type        = string
}

variable "region" {
  type = string
}

variable "subnet_ids" {
  description = "Subredes publicas (el servidor usa la primera; los agentes se reparten)"
  type        = list(string)
}

variable "nodes_security_group_id" {
  type = string
}

variable "lb_security_group_id" {
  type = string
}

variable "node_port" {
  description = "NodePort de Traefik expuesto al balanceador"
  type        = number
  default     = 30080
}

variable "k3s_version" {
  description = "Version fija de k3s para que el cluster sea reproducible"
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version debe ser una version estable completa, por ejemplo v1.31.4+k3s1."
  }
}

variable "server_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.small"
}

variable "agent_count" {
  type    = number
  default = 3
}

variable "instance_profile" {
  description = "Perfil EC2 precreado por AWS Academy (LabInstanceProfile); el sandbox no permite crear roles IAM"
  type        = string
  default     = "LabInstanceProfile"
}

variable "key_name" {
  description = "Par de claves EC2. Null = sin SSH; el acceso es por SSM Session Manager."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI fija. Vacio = ultima Amazon Linux 2023 en la primera creacion (luego se ignora)."
  type        = string
  default     = ""
}

variable "ami_ssm_parameter" {
  type    = string
  default = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = var.ami_ssm_parameter
}

locals {
  ami_id          = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ami[0].value
  token_parameter = "/${var.name_prefix}/k3s-token"
  agents          = { for i in range(var.agent_count) : "k3s-agent-${i + 1}" => i }
}

# Token compartido: generado por Terraform y guardado cifrado, nunca en el repositorio.
resource "random_id" "k3s_token" {
  byte_length = 32
}

resource "aws_ssm_parameter" "k3s_token" {
  name  = local.token_parameter
  type  = "SecureString"
  value = random_id.k3s_token.hex
}

resource "aws_instance" "server" {
  ami                         = local.ami_id
  instance_type               = var.server_instance_type
  subnet_id                   = var.subnet_ids[0]
  vpc_security_group_ids      = [var.nodes_security_group_id]
  associate_public_ip_address = true
  iam_instance_profile        = var.instance_profile
  key_name                    = var.key_name

  user_data = templatefile("${path.module}/files/server.sh.tftpl", {
    hostname         = "k3s-server"
    region           = var.region
    k3s_version      = var.k3s_version
    token_parameter  = local.token_parameter
    traefik_manifest = file("${path.module}/files/traefik.yaml")
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp2"
    encrypted   = true
  }

  tags = {
    Name = "${var.name_prefix}-k3s-server"
    Role = "k3s-server"
  }

  lifecycle {
    # Una AMI mas nueva no debe recrear los nodos en un plan posterior.
    ignore_changes = [ami]
  }

  depends_on = [aws_ssm_parameter.k3s_token]
}

resource "aws_instance" "agent" {
  for_each = local.agents

  ami                         = local.ami_id
  instance_type               = var.agent_instance_type
  subnet_id                   = element(var.subnet_ids, each.value)
  vpc_security_group_ids      = [var.nodes_security_group_id]
  associate_public_ip_address = true
  iam_instance_profile        = var.instance_profile
  key_name                    = var.key_name

  user_data = templatefile("${path.module}/files/agent.sh.tftpl", {
    hostname        = each.key
    region          = var.region
    k3s_version     = var.k3s_version
    token_parameter = local.token_parameter
    server_ip       = aws_instance.server.private_ip
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 15
    volume_type = "gp2"
    encrypted   = true
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}"
    Role = "k3s-agent"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_ssm_parameter.k3s_token]
}

# Classic ELB (como el stack original): reparte el puerto 80 hacia Traefik en los agentes.
# Excepción temporal AWS-0053: endpoint HTTP público requerido por la demo;
# el grupo del ELB solo acepta puerto 80 y los nodos no admiten entrada pública.
#trivy:ignore:AVD-AWS-0053:exp:2027-04-27
resource "aws_elb" "this" {
  # ELB HTTP público requerido para la demo académica; los nodos no exponen
  # entrada pública y el SG del ELB solo admite HTTP por el puerto 80.
  name            = "${var.name_prefix}-elb"
  subnets         = var.subnet_ids
  security_groups = [var.lb_security_group_id]
  instances       = [for a in aws_instance.agent : a.id]

  cross_zone_load_balancing = true
  idle_timeout              = 120

  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = var.node_port
    instance_protocol = "http"
  }

  health_check {
    target              = "HTTP:${var.node_port}/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 10
    timeout             = 5
  }
}

output "elb_url" {
  value = "http://${aws_elb.this.dns_name}"
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "agent_instance_ids" {
  value = { for k, a in aws_instance.agent : k => a.id }
}
