output "dashboard_name" {
  value = aws_cloudwatch_dashboard.vibe.dashboard_name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.vibe.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic para alarmas; null si no se configuro correo."
  value       = local.alarms_topic_arn
}

output "alarm_names" {
  value = concat(
    [for alarm in aws_cloudwatch_metric_alarm.instance_status : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.instance_cpu : alarm.alarm_name],
    [
      aws_cloudwatch_metric_alarm.elb_unhealthy_hosts.alarm_name,
      aws_cloudwatch_metric_alarm.elb_healthy_hosts_low.alarm_name,
      aws_cloudwatch_metric_alarm.elb_latency_high.alarm_name,
      aws_cloudwatch_metric_alarm.elb_backend_5xx.alarm_name
    ]
  )
}
