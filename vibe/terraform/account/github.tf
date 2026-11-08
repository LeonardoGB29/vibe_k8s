# Opcional (enable_github_oidc): algunas cuentas (p. ej. proyectos con SCP gestionadas) prohiben
# iam:CreateOpenIDConnectProvider. Autenticacion de GitHub Actions con OIDC: sin claves ni tokens de sesion en
# GitHub. Los nombres github-vibe-* NO empiezan por "vibe-" a proposito: asi el
# rol de Terraform no puede modificarse a si mismo ni al de despliegue.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  count = var.enable_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for e in var.github_environments : "repo:${var.github_repository}:environment:${e}"]
    }
  }
}

# --- Despliegue de la aplicacion (deploy.yml): minimo privilegio ---
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "RunDeployScript"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunOnVibeInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["vibe"]
    }
  }

  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid       = "FindServer"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "FindLoadBalancer"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }

  statement {
    sid       = "UploadPackage"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::vibe-*-audio-raw-${local.account_id}/deployment/*"]
  }
}

resource "aws_iam_role" "github_deploy" {
  count                = var.enable_github_oidc ? 1 : 0
  name                 = "github-vibe-deploy"
  description          = "deploy.yml: despliega imagenes por SSM"
  assume_role_policy   = data.aws_iam_policy_document.github_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_deploy" {
  count  = var.enable_github_oidc ? 1 : 0
  name   = "deploy"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# --- Terraform plan/apply/destroy (terraform.yml) ---
# PowerUserAccess cubre EC2/RDS/ELB/S3/SSM/CloudWatch/SNS pero no IAM; IAM se
# concede solo para los roles de nodos (vibe-<entorno>-node).
data "aws_iam_policy_document" "github_terraform" {
  statement {
    sid = "NodeRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:PassRole",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile", "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/vibe-*-node",
      "arn:aws:iam::${local.account_id}:instance-profile/vibe-*-node",
    ]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["rds.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid    = "ProtectCreditGuard"
    effect = "Deny"
    actions = [
      "lambda:*", "events:DeleteRule", "events:DisableRule", "events:PutRule", "events:RemoveTargets", "events:PutTargets",
    ]
    resources = [
      aws_lambda_function.guard.arn,
      aws_cloudwatch_event_rule.guard.arn,
    ]
  }
}

resource "aws_iam_role" "github_terraform" {
  count                = var.enable_github_oidc ? 1 : 0
  name                 = "github-vibe-terraform"
  description          = "terraform.yml: plan/apply/destroy de los entornos"
  assume_role_policy   = data.aws_iam_policy_document.github_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_terraform_poweruser" {
  count      = var.enable_github_oidc ? 1 : 0
  role       = aws_iam_role.github_terraform[0].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "github_terraform" {
  count  = var.enable_github_oidc ? 1 : 0
  name   = "iam-nodos-y-proteccion"
  role   = aws_iam_role.github_terraform[0].id
  policy = data.aws_iam_policy_document.github_terraform.json
}
