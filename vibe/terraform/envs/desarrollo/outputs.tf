output "elb_url" {
  description = "URL publica de la aplicacion"
  value       = module.cluster.elb_url
}

output "raw_bucket" {
  value = module.storage.raw_bucket
}

output "hls_bucket" {
  value = module.storage.hls_bucket
}

output "server_instance_id" {
  value = module.cluster.server_instance_id
}

output "ssm_session_command" {
  description = "Acceso al servidor sin SSH ni puertos abiertos"
  value       = "aws ssm start-session --target ${module.cluster.server_instance_id} --region ${var.region}"
}

output "cluster_init_command" {
  description = "Comando para desplegar la aplicacion dentro del servidor"
  value       = "bash aws/cluster-init.sh ${module.storage.raw_bucket} ${module.storage.hls_bucket}"
}

output "cloudwatch_dashboard_url" {
  description = "Dashboard CloudWatch de operacion VIBE"
  value       = module.monitoring.dashboard_url
}

output "cloudwatch_alarm_names" {
  description = "Alarmas EC2 y Classic ELB creadas para VIBE"
  value       = module.monitoring.alarm_names
}

output "cloudwatch_alerts_topic_arn" {
  description = "Topic SNS opcional para alertas por correo"
  value       = module.monitoring.alerts_topic_arn
}
