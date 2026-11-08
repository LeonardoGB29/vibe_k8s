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
