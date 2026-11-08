variable "region" {
  description = "Región de la cuenta (la asignada al proyecto)"
  type        = string
  default     = "us-east-2"
}

variable "alert_email" {
  description = "Correo para avisos del guardián de créditos (SNS pide confirmar la suscripción)"
  type        = string
  default     = ""
}

variable "stop_below_usd" {
  description = "Se pausan EC2 y RDS cuando los créditos restantes bajan de este valor. El saldo se actualiza con retraso (horas): deja margen."
  type        = number
  default     = 20

  validation {
    condition     = var.stop_below_usd >= 0 && var.stop_below_usd <= 100
    error_message = "stop_below_usd debe estar entre 0 y 100."
  }
}

variable "warn_below_usd" {
  description = "Aviso diario por correo cuando los créditos restantes bajan de este valor"
  type        = number
  default     = 50
}

variable "guard_dry_run" {
  description = "true = el guardián solo registra lo que detendría, sin detener nada"
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "Repositorio autorizado a asumir los roles OIDC (owner/nombre)"
  type        = string
  default     = "LeonardoGB29/vibe_k8s"
}

variable "github_environments" {
  description = "GitHub Environments autorizados"
  type        = list(string)
  default     = ["desarrollo", "staging", "produccion"]
}

variable "enable_github_oidc" {
  description = "Crea el proveedor OIDC y los roles de GitHub Actions. Desactivado por defecto: las SCP de los proyectos gestionados deniegan iam:CreateOpenIDConnectProvider."
  type        = bool
  default     = false
}

variable "enable_ci_deploy_user" {
  description = "Crea el usuario IAM github-vibe-deploy (permisos minimos de despliegue) para deploy.yml. La clave de acceso se crea a mano con la CLI."
  type        = bool
  default     = true
}
