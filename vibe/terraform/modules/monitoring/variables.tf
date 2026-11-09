variable "name_prefix" {
  description = "Prefijo compartido con los recursos de VIBE."
  type        = string
}

variable "region" {
  type = string
}

variable "elb_name" {
  type = string
}

variable "instance_ids" {
  description = "IDs de las instancias fijas del clúster (servidor y, sin autoescalado, los agentes)."
  type        = map(string)
}

variable "asg_name" {
  description = "Auto Scaling Group de agentes (entornos con Cluster Autoscaler). Sus instancias son efimeras, asi que se vigilan como grupo y no una a una. Vacio = sin ASG."
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "Minimo de agentes del ASG: la alarma avisa si hay menos instancias en servicio que este numero."
  type        = number
  default     = 0
}

variable "alert_email" {
  description = "Destino opcional de las alarmas. SNS requiere confirmar la suscripcion desde el correo recibido."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email debe estar vacio o tener formato de correo valido."
  }
}
