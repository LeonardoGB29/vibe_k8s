terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

locals {
  alarms_topic_arn = var.alert_email == "" ? null : aws_sns_topic.alerts[0].arn
  alarm_actions    = var.alert_email == "" ? [] : [local.alarms_topic_arn]

  ec2_metrics = [
    for node_name, instance_id in var.instance_ids : [
      ["AWS/EC2", "CPUUtilization", "InstanceId", instance_id],
      ["AWS/EC2", "StatusCheckFailed", "InstanceId", instance_id, { stat = "Maximum", yAxis = "right" }]
    ]
  ]

  has_asg = var.asg_name != ""
  # Los widgets del ASG van debajo de los de las instancias fijas (2 por fila, 6 de alto).
  asg_widgets_y = 6 + ceil(length(var.instance_ids) / 2) * 6
}

resource "aws_sns_topic" "alerts" {
  count = var.alert_email == "" ? 0 : 1
  name  = "${var.name_prefix}-cloudwatch-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  for_each = var.instance_ids

  alarm_name          = "${var.name_prefix}-${each.key}-status-check"
  alarm_description   = "Al menos una comprobacion de estado de EC2 fallo durante dos minutos."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-${each.key}-status-check" }
}

resource "aws_cloudwatch_metric_alarm" "instance_cpu" {
  for_each = var.instance_ids

  alarm_name          = "${var.name_prefix}-${each.key}-cpu-high"
  alarm_description   = "El uso promedio de CPU de EC2 supero 85% en tres periodos consecutivos de cinco minutos."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-${each.key}-cpu-high" }
}

# Agentes con autoescalado: las instancias nacen y mueren, asi que no hay alarma por instancia.
# Se vigila el grupo: CPU media de todos los agentes y que no queden menos en servicio que el minimo.
resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  count = local.has_asg ? 1 : 0

  alarm_name          = "${var.name_prefix}-agents-cpu-high"
  alarm_description   = "El uso medio de CPU de los agentes (Auto Scaling Group) supero 85% en tres periodos consecutivos de cinco minutos."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-agents-cpu-high" }
}

resource "aws_cloudwatch_metric_alarm" "asg_in_service_low" {
  count = local.has_asg && var.asg_min_size > 0 ? 1 : 0

  alarm_name          = "${var.name_prefix}-agents-in-service-low"
  alarm_description   = "Hay menos agentes en servicio que el minimo del Auto Scaling Group durante cinco minutos seguidos."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = var.asg_min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-agents-in-service-low" }
}

resource "aws_cloudwatch_metric_alarm" "elb_unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-elb-unhealthy-hosts"
  alarm_description   = "El Classic Load Balancer reporto al menos un agente no saludable."
  namespace           = "AWS/ELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancerName = var.elb_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-elb-unhealthy-hosts" }
}

resource "aws_cloudwatch_metric_alarm" "elb_healthy_hosts_low" {
  alarm_name          = "${var.name_prefix}-elb-healthy-hosts-low"
  alarm_description   = "Quedan menos nodos saludables en el balanceador de los esperados (2, o 1 si el clúster tiene un solo nodo)."
  namespace           = "AWS/ELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancerName = var.elb_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = min(2, length(var.instance_ids) + var.asg_min_size)
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-elb-healthy-hosts-low" }
}

resource "aws_cloudwatch_metric_alarm" "elb_latency_high" {
  alarm_name          = "${var.name_prefix}-elb-latency-high"
  alarm_description   = "La latencia promedio del Classic ELB supero dos segundos durante tres periodos de cinco minutos."
  namespace           = "AWS/ELB"
  metric_name         = "Latency"
  dimensions          = { LoadBalancerName = var.elb_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-elb-latency-high" }
}

resource "aws_cloudwatch_metric_alarm" "elb_backend_5xx" {
  alarm_name          = "${var.name_prefix}-elb-backend-5xx"
  alarm_description   = "El balanceador conto cinco o mas respuestas HTTP 5xx de los agentes en cinco minutos."
  namespace           = "AWS/ELB"
  metric_name         = "HTTPCode_Backend_5XX"
  dimensions          = { LoadBalancerName = var.elb_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-elb-backend-5xx" }
}

resource "aws_cloudwatch_dashboard" "vibe" {
  dashboard_name = "${var.name_prefix}-operations"
  dashboard_body = jsonencode({
    widgets = concat(
      [{
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title   = "Classic ELB: trafico, errores, latencia y salud"
          region  = var.region
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ELB", "RequestCount", "LoadBalancerName", var.elb_name, { stat = "Sum", yAxis = "left" }],
            ["AWS/ELB", "HTTPCode_Backend_5XX", "LoadBalancerName", var.elb_name, { stat = "Sum", yAxis = "left" }],
            ["AWS/ELB", "Latency", "LoadBalancerName", var.elb_name, { stat = "Average", yAxis = "right" }],
            ["AWS/ELB", "HealthyHostCount", "LoadBalancerName", var.elb_name, { stat = "Minimum", yAxis = "right" }],
            ["AWS/ELB", "UnHealthyHostCount", "LoadBalancerName", var.elb_name, { stat = "Maximum", yAxis = "right" }]
          ]
        }
      }],
      [
        for index, instance_metrics in local.ec2_metrics : {
          type   = "metric"
          x      = (index % 2) * 12
          y      = 6 + floor(index / 2) * 6
          width  = 12
          height = 6
          properties = {
            title   = "K3s EC2 ${keys(var.instance_ids)[index]}: CPU y estado"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = instance_metrics
          }
        }
      ],
      local.has_asg ? [
        {
          type   = "metric"
          x      = 0
          y      = local.asg_widgets_y
          width  = 12
          height = 6
          properties = {
            title   = "Agentes (Auto Scaling Group): nodos en servicio y capacidad"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = [
              ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average" }],
              ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", var.asg_name, { stat = "Average" }],
              ["AWS/AutoScaling", "GroupPendingInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average" }],
              ["AWS/AutoScaling", "GroupMinSize", "AutoScalingGroupName", var.asg_name, { stat = "Average" }],
              ["AWS/AutoScaling", "GroupMaxSize", "AutoScalingGroupName", var.asg_name, { stat = "Average" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = local.asg_widgets_y
          width  = 12
          height = 6
          properties = {
            title   = "Agentes (Auto Scaling Group): CPU media y maxima"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = [
              ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { stat = "Average" }],
              ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { stat = "Maximum" }]
            ]
          }
        }
      ] : []
    )
  })
}
