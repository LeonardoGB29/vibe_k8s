output "identifier" {
  value = aws_db_instance.this.identifier
}

output "address" {
  description = "Endpoint privado de PostgreSQL."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "multi_az" {
  value = aws_db_instance.this.multi_az
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_password" {
  value     = random_password.master.result
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.this.id
}
