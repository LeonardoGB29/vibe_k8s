data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  guard_name = "vibe-credit-guard"
}

data "archive_file" "guard" {
  type        = "zip"
  source_file = "${path.module}/credit_guard/handler.py"
  output_path = "${path.module}/.build/credit_guard.zip"
}

# Excepción temporal AWS-0095: el tema solo lleva avisos de saldo y nombres de alarma
# (sin datos sensibles). Con la clave gestionada alias/aws/sns las alarmas de CloudWatch
# no pueden publicar (el aviso "el guardián falló" dejaría de llegar) y una clave KMS
# propia cuesta ~1 USD/mes.
#trivy:ignore:AVD-AWS-0095:exp:2027-04-27
resource "aws_sns_topic" "guard" {
  name = "${local.guard_name}-alerts"
}

resource "aws_sns_topic_subscription" "guard_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.guard.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_log_group" "guard" {
  name              = "/aws/lambda/${local.guard_name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "guard_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "guard" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.guard.arn}:*"]
  }

  statement {
    sid       = "ReadCredits"
    actions   = ["freetier:GetAccountPlanState"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeCompute"
    actions   = ["ec2:DescribeInstances", "rds:DescribeDBInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "StopTaggedInstances"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["vibe"]
    }
  }

  statement {
    sid       = "ReadDatabaseTags"
    actions   = ["rds:ListTagsForResource"]
    resources = ["arn:aws:rds:${var.region}:${local.account_id}:db:*"]
  }

  statement {
    sid       = "StopVibeDatabases"
    actions   = ["rds:StopDBInstance"]
    resources = ["arn:aws:rds:${var.region}:${local.account_id}:db:vibe-*"]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.guard.arn]
  }
}

resource "aws_iam_role" "guard" {
  name               = local.guard_name
  assume_role_policy = data.aws_iam_policy_document.guard_assume.json
}

resource "aws_iam_role_policy" "guard" {
  name   = local.guard_name
  role   = aws_iam_role.guard.id
  policy = data.aws_iam_policy_document.guard.json
}

resource "aws_lambda_function" "guard" {
  function_name    = local.guard_name
  description      = "Pausa EC2/RDS de VIBE cuando los creditos de la cuenta bajan del umbral"
  role             = aws_iam_role.guard.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.guard.output_path
  source_code_hash = data.archive_file.guard.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      PROJECT_TAG    = "vibe"
      STOP_BELOW_USD = tostring(var.stop_below_usd)
      WARN_BELOW_USD = tostring(var.warn_below_usd)
      DRY_RUN        = tostring(var.guard_dry_run)
      TOPIC_ARN      = aws_sns_topic.guard.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.guard, aws_iam_role_policy.guard]
}

resource "aws_cloudwatch_event_rule" "guard" {
  name                = "${local.guard_name}-hourly"
  description         = "Revisa el saldo de creditos cada hora"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "guard" {
  rule = aws_cloudwatch_event_rule.guard.name
  arn  = aws_lambda_function.guard.arn
}

resource "aws_lambda_permission" "guard" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guard.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guard.arn
}

# Si el guardián falla (no puede leer créditos o parar algo) hay que enterarse.
resource "aws_cloudwatch_metric_alarm" "guard_errors" {
  alarm_name          = "${local.guard_name}-errors"
  alarm_description   = "El guardian de creditos fallo: puede que no este protegiendo la cuenta."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.guard.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.guard.arn]
}
