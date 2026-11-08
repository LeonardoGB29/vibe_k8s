terraform {
  backend "s3" {
    key          = "produccion/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
