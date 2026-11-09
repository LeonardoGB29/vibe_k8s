variable "region" {
  type    = string
  default = "us-east-2"
}

variable "environment" {
  type    = string
  default = "desarrollo"
}

variable "k3s_version" {
  description = "Version fija de k3s"
  type        = string
  default     = "v1.31.4+k3s1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version debe ser una version estable completa, por ejemplo v1.31.4+k3s1."
  }
}

variable "server_instance_type" {
  type    = string
  default = "c7i-flex.large"

  validation {
    condition     = contains(["c7i-flex.large", "m7i-flex.large", "t3.medium", "t2.medium"], var.server_instance_type)
    error_message = "El servidor construye imagenes y corre el control plane (>= 4 GB): c7i-flex.large o m7i-flex.large en el plan gratuito, o t3.medium/t2.medium en una cuenta de pago."
  }
}

variable "agent_instance_type" {
  type    = string
  default = "t3.small"

  validation {
    condition     = contains(["t3.small", "t3.micro", "t2.small", "t2.micro"], var.agent_instance_type)
    error_message = "Tipos permitidos para agentes: t3.small, t3.micro, t2.small, t2.micro."
  }
}

variable "agent_count" {
  description = "Agentes k3s (desarrollo). 0 = un solo nodo; sube el valor (aws/scale-aws.sh) para escalar horizontalmente."
  type        = number
  default     = 0

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 6
    error_message = "agent_count debe estar entre 0 y 6 (0 = un solo nodo: el servidor ejecuta también los pods)."
  }
}


variable "key_name" {
  description = "Par de claves EC2 (null = sin SSH, acceso por SSM)"
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI fija; vacio usa la ultima Amazon Linux 2023 solo al crear"
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Correo opcional para alarmas CloudWatch. AWS SNS solicita confirmar la suscripcion."
  type        = string
  default     = ""
}
