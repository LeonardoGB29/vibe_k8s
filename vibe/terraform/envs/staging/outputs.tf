output "db_identifier" {
  value = module.postgres.identifier
}

output "db_address" {
  value = module.postgres.address
}

output "db_port" {
  value = module.postgres.port
}

output "db_name" {
  value = module.postgres.database_name
}

output "db_multi_az" {
  value = module.postgres.multi_az
}

output "db_username" {
  value = module.postgres.master_username
}

output "db_password" {
  value     = module.postgres.master_password
  sensitive = true
}
