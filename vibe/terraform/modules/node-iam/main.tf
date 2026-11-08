terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

# Rol de los nodos k3s:
# SSM (Session Manager / Run Command), CloudWatch Agent (memoria y logs),
# lectura del token de k3s y acceso solo a los buckets de audio del entorno.
variable "name_prefix" {
  description = "Prefijo de los recursos (ej. vibe-desarrollo)"
  type        = string
}

variable "bucket_names" {
  description = "Buckets S3 a los que pueden acceder las aplicaciones"
  type        = list(string)
}

variable "token_parameter" {
  description = "Nombre del parametro SSM con el token de k3s"
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-node"
  description        = "Nodos k3s de ${var.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "node" {
  statement {
    sid       = "ReadK3sToken"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.token_parameter}"]
  }

  statement {
    sid       = "ListAudioBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [for b in var.bucket_names : "arn:aws:s3:::${b}"]
  }

  statement {
    sid       = "ReadWriteAudioObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = [for b in var.bucket_names : "arn:aws:s3:::${b}/*"]
  }
}

resource "aws_iam_role_policy" "node" {
  name   = "${var.name_prefix}-node"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-node"
  role = aws_iam_role.node.name
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}
