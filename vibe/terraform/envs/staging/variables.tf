variable "environment" {
  type    = string
  default = "staging"
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
  default = "t3.medium"

  validation {
    condition     = contains(["t3.medium", "t2.medium"], var.server_instance_type)
    error_message = "El servidor construye imagenes y corre el control plane: usa t3.medium o t2.medium."
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
  description = "Agentes k3s (staging). Cada uno son 2 vCPU; con el servidor suman 2 x (agent_count + 1)."
  type        = number
  default     = 2

  validation {
    condition     = var.agent_count >= 1 && var.agent_count <= 6
    error_message = "agent_count debe estar entre 1 y 6."
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

variable "region" {
  description = "Región de la cuenta AWS."
  type        = string
  default     = "us-east-2"
}

variable "instance_class" {
  description = "Clase RDS PostgreSQL (db.t3.micro cuesta ~0,018 USD/h Single-AZ)."
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  type    = string
  default = "16.15"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 30
}
