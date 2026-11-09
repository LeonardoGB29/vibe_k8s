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
  default = "c7i-flex.large"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.small"
}

variable "agent_count" {
  type    = number
  default = 3
}

variable "autoscaling_enabled" {
  description = "true = los agentes viven en un Auto Scaling Group que el Cluster Autoscaler escala (agent_count pasa a ser el minimo)."
  type        = bool
  default     = false
}

variable "agent_max" {
  description = "Maximo de agentes del Auto Scaling Group (solo con autoscaling_enabled). Limitado por la cuota de vCPU de EC2."
  type        = number
  default     = 6

  validation {
    condition     = var.agent_max >= 1 && var.agent_max <= 20
    error_message = "agent_max debe estar entre 1 y 20."
  }
}

variable "instance_profile" {
  description = "Perfil de instancia EC2 de los nodos (lo crea modules/node-iam)"
  type        = string
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
  # Con autoscaling no hay instancias fijas: las crea el Auto Scaling Group.
  agents = var.autoscaling_enabled ? {} : { for i in range(var.agent_count) : "k3s-agent-${i + 1}" => i }
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
    # 2 saltos: los pods (un salto mas que el host) pueden leer las credenciales del rol de la
    # instancia en IMDSv2. Con el valor por defecto (1) quedarian bloqueados.
    http_put_response_hop_limit = 2
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
    # 2 saltos: los pods (un salto mas que el host) pueden leer las credenciales del rol de la
    # instancia en IMDSv2. Con el valor por defecto (1) quedarian bloqueados.
    http_put_response_hop_limit = 2
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

# Agentes con autoescalado: plantilla de lanzamiento + Auto Scaling Group. El Cluster Autoscaler
# (dentro del clúster) descubre el grupo por las etiquetas k8s.io/cluster-autoscaler/* y cambia
# su capacidad deseada entre agent_count (minimo) y agent_max cuando hay pods sin sitio (Pending)
# o nodos sobrantes.
resource "aws_launch_template" "agent" {
  count = var.autoscaling_enabled ? 1 : 0

  name_prefix   = "${var.name_prefix}-k3s-agent-"
  image_id      = local.ami_id
  instance_type = var.agent_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.nodes_security_group_id]
  }

  user_data = base64encode(templatefile("${path.module}/files/agent-asg.sh.tftpl", {
    region          = var.region
    k3s_version     = var.k3s_version
    token_parameter = local.token_parameter
    server_ip       = aws_instance.server.private_ip
  }))

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 2 saltos: los pods pueden leer las credenciales del rol de la instancia (IMDSv2).
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 15
      volume_type = "gp2"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-k3s-agent"
      Role = "k3s-agent"
    }
  }

  depends_on = [aws_ssm_parameter.k3s_token]
}

resource "aws_autoscaling_group" "agent" {
  count = var.autoscaling_enabled ? 1 : 0

  name                = "${var.name_prefix}-k3s-agents"
  min_size            = var.agent_count
  max_size            = var.agent_max
  desired_capacity    = var.agent_count
  vpc_zone_identifier = var.subnet_ids
  load_balancers      = [aws_elb.this.name]
  health_check_type   = "EC2"
  # El Cluster Autoscaler decide cuándo escalar; AZRebalance movería nodos por su cuenta.
  suspended_processes = ["AZRebalance"]

  # Metricas del grupo (AWS/AutoScaling) para el panel y las alarmas de modules/monitoring.
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.agent[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-k3s-agent"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "k3s-agent"
    propagate_at_launch = true
  }
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.name_prefix}"
    value               = "owned"
    propagate_at_launch = false
  }

  lifecycle {
    # La capacidad deseada la maneja el Cluster Autoscaler: un apply no debe deshacerla.
    ignore_changes = [desired_capacity]
  }
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
  # El servidor tambien ejecuta pods (k3s no lo marca como no programable) y el NodePort de
  # Traefik responde en cualquier nodo: asi un clúster de un solo nodo (agent_count = 0) tiene
  # trafico y al añadir agentes se reparte entre todos.
  # Con autoscaling los agentes los registra el Auto Scaling Group (load_balancers) y el servidor
  # se adjunta con aws_elb_attachment; listar instancias aqui las desregistraria en cada apply.
  instances = var.autoscaling_enabled ? null : concat([aws_instance.server.id], [for a in aws_instance.agent : a.id])

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

resource "aws_elb_attachment" "server" {
  count = var.autoscaling_enabled ? 1 : 0

  elb      = aws_elb.this.id
  instance = aws_instance.server.id
}

output "autoscaling_enabled" {
  value = var.autoscaling_enabled
}

output "agent_asg_name" {
  value = var.autoscaling_enabled ? aws_autoscaling_group.agent[0].name : null
}

output "elb_url" {
  value = "http://${aws_elb.this.dns_name}"
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "elb_name" {
  value = aws_elb.this.name
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "agent_instance_ids" {
  value = { for k, a in aws_instance.agent : k => a.id }
}

output "instance_ids" {
  value = merge(
    { "k3s-server" = aws_instance.server.id },
    { for name, agent in aws_instance.agent : name => agent.id }
  )
}
