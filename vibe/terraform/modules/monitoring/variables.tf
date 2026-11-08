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
  description = "IDs del servidor K3s y sus agentes."
  type        = map(string)
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
