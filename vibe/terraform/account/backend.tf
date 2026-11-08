# Recursos de cuenta (guardian de creditos, roles OIDC de GitHub). Se aplica en
# local con aws/init-account.sh; el bucket del state se crea con AWS CLI:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "account/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
