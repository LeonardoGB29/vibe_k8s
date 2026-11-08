variable "region" {
  description = "Región del Learner Lab."
  type        = string
  default     = "us-east-1"
}

variable "instance_class" {
  description = "Clase RDS PostgreSQL permitida por AWS Academy."
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  type    = string
  default = "16.16"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 30
}
