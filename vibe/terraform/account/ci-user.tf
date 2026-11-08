# Usuario de CI para deploy.yml. Las SCP de este proyecto prohiben el proveedor OIDC de
# GitHub, asi que el workflow se autentica con una clave de acceso de este usuario.
# - Permisos minimos: solo despliegue por SSM en EC2 etiquetadas Project=vibe, subir el
#   paquete a deployment/ y leer EC2/ELB (misma politica que el rol OIDC opcional).
# - NO se crea la clave aqui, para que el secreto no quede en el state de Terraform:
#     aws iam create-access-key --user-name github-vibe-deploy
#   Guarda AccessKeyId/SecretAccessKey como secretos de los GitHub Environments y rota la
#   clave cada ~90 dias (create-access-key de la nueva, actualizar el secreto, delete-access-key de la vieja).
resource "aws_iam_user" "ci_deploy" {
  count = var.enable_ci_deploy_user ? 1 : 0
  name  = "github-vibe-deploy"
}

resource "aws_iam_user_policy" "ci_deploy" {
  count  = var.enable_ci_deploy_user ? 1 : 0
  name   = "deploy"
  user   = aws_iam_user.ci_deploy[0].name
  policy = data.aws_iam_policy_document.github_deploy.json
}
