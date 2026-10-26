variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "desarrollo"
}

variable "k3s_version" {
  description = "Version fija de k3s"
  type        = string
  default     = "v1.31.4+k3s1"
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
  type    = number
  default = 3

  validation {
    condition     = var.agent_count >= 1 && var.agent_count <= 6
    error_message = "agent_count debe estar entre 1 y 6."
  }
}

variable "instance_profile" {
  type    = string
  default = "LabInstanceProfile"
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
