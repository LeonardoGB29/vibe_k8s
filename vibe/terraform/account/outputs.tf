output "credit_guard_function" {
  value = aws_lambda_function.guard.function_name
}

output "credit_guard_topic_arn" {
  value = aws_sns_topic.guard.arn
}

output "github_deploy_role_arn" {
  description = "Variable AWS_DEPLOY_ROLE_ARN del Environment (solo con enable_github_oidc)"
  value       = one(aws_iam_role.github_deploy[*].arn)
}

output "github_terraform_role_arn" {
  description = "Variable AWS_ROLE_ARN del Environment (solo con enable_github_oidc)"
  value       = one(aws_iam_role.github_terraform[*].arn)
}

output "ci_deploy_user" {
  description = "Usuario de CI; crea su clave con: aws iam create-access-key --user-name <este valor>"
  value       = one(aws_iam_user.ci_deploy[*].name)
}
