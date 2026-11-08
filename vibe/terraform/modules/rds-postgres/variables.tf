variable "identifier" {
  description = "Identificador DNS único de la instancia RDS."
  type        = string
}

variable "environment" {
  description = "Nombre del entorno para tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC donde se crea RDS."
  type        = string
}

variable "subnet_ids" {
  description = "Subredes de al menos dos zonas de disponibilidad."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "El grupo de subredes de RDS debe cubrir al menos dos subredes."
  }
}

variable "client_security_group_id" {
  description = "Security group de los nodos K3s autorizados a conectarse."
  type        = string
}

variable "database_name" {
  description = "Base de datos inicial creada por RDS."
  type        = string
  default     = "vibe"
}

variable "master_username" {
  description = "Usuario administrador de PostgreSQL."
  type        = string
  default     = "vibeadmin"
}

variable "instance_class" {
  description = "Clase RDS admitida por AWS Academy."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = contains(["db.t3.micro", "db.t3.small", "db.t3.medium"], var.instance_class)
    error_message = "Usa una clase pequeña permitida por Learner Lab: db.t3.micro, db.t3.small o db.t3.medium."
  }
}

variable "engine_version" {
  description = "Versión PostgreSQL; la predeterminada fue observada en las opciones RDS de us-east-1."
  type        = string
  default     = "16.16"
}

variable "allocated_storage" {
  description = "Almacenamiento gp2 en GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 100
    error_message = "Learner Lab permite hasta 100 GB; RDS PostgreSQL requiere al menos 20 GB en esta configuración."
  }
}

variable "max_allocated_storage" {
  description = "Límite de autoscaling del volumen gp2 en GiB."
  type        = number
  default     = 40

  validation {
    condition     = var.max_allocated_storage >= var.allocated_storage && var.max_allocated_storage <= 100
    error_message = "max_allocated_storage debe ser >= allocated_storage y <= 100 GB."
  }
}

variable "multi_az" {
  description = "Activa standby síncrono en otra zona para la simulación de producción."
  type        = bool
}

variable "backup_retention_days" {
  description = "Retención de backups automáticos."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 7
    error_message = "Para controlar el costo del laboratorio, configura una retención entre 1 y 7 días."
  }
}
