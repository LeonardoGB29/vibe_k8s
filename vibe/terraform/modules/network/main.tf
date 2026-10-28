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
  description = "Prefijo de los recursos (ej. vibe-desarrollo)"
  type        = string
}

variable "node_port" {
  description = "NodePort de Traefik al que apunta el balanceador"
  type        = number
  default     = 30080
}

# Red: se reutiliza la VPC predeterminada disponible en el sandbox de AWS Academy.
# La salida global se conserva temporalmente para descargar paquetes del sistema,
# imágenes de contenedor y releases de k3s/KEDA/Helm: el sandbox no permite crear
# endpoints privados ni reglas de egress por servicio. No hay puertos de entrada
# abiertos en los nodos; el balanceador solo llega al NodePort configurado.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  subnet_by_az = { for s in data.aws_subnet.public : s.availability_zone => s.id }
  # Ordenadas por zona para que el resultado sea estable entre ejecuciones.
  sorted_subnets = [for az in sort(keys(local.subnet_by_az)) : local.subnet_by_az[az]]
  subnet_ids     = slice(local.sorted_subnets, 0, min(3, length(local.sorted_subnets)))
}

check "three_azs" {
  assert {
    condition     = length(local.subnet_ids) == 3
    error_message = "Se necesitan tres subredes publicas predeterminadas en zonas distintas."
  }
}

# Balanceador: unico punto publico, solo puerto 80.
resource "aws_security_group" "lb" {
  name        = "${var.name_prefix}-lb"
  description = "Balanceador de VIBE: HTTP publico"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.name_prefix}-lb" }
}

# Nodos: sin puertos publicos. Se administran con SSM Session Manager (sin SSH ni 6443 abiertos).
resource "aws_security_group" "nodes" {
  name        = "${var.name_prefix}-nodes"
  description = "Nodos k3s de VIBE: solo trafico interno y desde el balanceador"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.name_prefix}-nodes" }
}

resource "aws_vpc_security_group_ingress_rule" "lb_http" {
  security_group_id = aws_security_group.lb.id
  description       = "HTTP publico"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "lb_to_nodes" {
  security_group_id            = aws_security_group.lb.id
  description                  = "Trafico y health check hacia Traefik"
  ip_protocol                  = "tcp"
  from_port                    = var.node_port
  to_port                      = var.node_port
  referenced_security_group_id = aws_security_group.nodes.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_lb" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Traefik NodePort desde el balanceador"
  ip_protocol                  = "tcp"
  from_port                    = var.node_port
  to_port                      = var.node_port
  referenced_security_group_id = aws_security_group.lb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Comunicacion entre nodos (API 6443, kubelet, flannel)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  description       = "Salida a Internet (imagenes, k3s, S3, SSM)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "Tres subredes publicas ordenadas por zona de disponibilidad"
  value       = local.subnet_ids
}

output "lb_security_group_id" {
  value = aws_security_group.lb.id
}

output "nodes_security_group_id" {
  value = aws_security_group.nodes.id
}
