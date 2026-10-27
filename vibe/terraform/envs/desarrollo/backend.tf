# El nombre del bucket depende de la cuenta, por eso no esta fijo aqui:
#   terraform init -backend-config=backend.hcl
# (copia backend.hcl.example a backend.hcl con el output `state_bucket` de terraform/bootstrap).
# use_lockfile = bloqueo del state con un objeto .tflock en S3, sin DynamoDB.
terraform {
  backend "s3" {
    key          = "desarrollo/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
