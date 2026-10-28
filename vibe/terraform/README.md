# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      nombres de buckets S3 raw y hls
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
envs/desarrollo/      composicion del entorno desarrollo en AWS
```

`test` no usa Terraform: es un cluster kind (`make up`, o el job `test-kind` del CI).

## Despliegue en AWS Academy

```bash
cd aws
bash deploy-sandbox.sh
```

El script crea/configura los buckets con AWS CLI y usa Terraform para el resto
de la infraestructura. AWS Academy deniega `s3:GetBucketObjectLockConfiguration`,
que el proveedor AWS de Terraform requiere al leer un recurso `aws_s3_bucket`;
por eso el state y los buckets de audio no se administran como recursos Terraform.

## Decisiones

- **State:** S3 con versionado, cifrado, bloqueo (`use_lockfile`) y solo TLS. Un state por entorno (`desarrollo/terraform.tfstate`).
- **Minimo privilegio:** unico puerto publico el 80 del ELB; los nodos solo reciben el NodePort desde el ELB y trafico interno; sin SSH (SSM). El token de k3s sale de `random_id` y se guarda en SSM SecureString, no en el user-data ni en Git. IMDSv2 obligatorio, discos cifrados.
  Se reutiliza `LabInstanceProfile`/`LabRole`, precreados por el sandbox; IAM es de solo lectura y no se pueden crear roles propios. Las credenciales del CLI se obtienen en Lab IDE y caducan al cerrar la sesión.
- **Reproducibilidad:** versiones fijas de k3s, de providers (`~>`) y de Terraform (`>= 1.10`), `.terraform.lock.hcl` versionado, AMI ignorada tras la creacion (`ignore_changes`) para que un plan posterior no recree nodos.
- **Idempotencia:** `terraform plan` sin cambios debe salir vacio. KEDA y la aplicacion no estan en Terraform: las aplica `aws/cluster-init.sh` (`kubectl apply -k k8s/overlays/desarrollo`).

## GitHub Actions y credenciales

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales temporales del sandbox; renovarlas cada sesión solo si se ejecutan los workflows `terraform` o `deploy` |
| Variable | `TF_STATE_BUCKET` | `vibe-tfstate-<ACCOUNT_ID>` |

Los workflows `ci` y `image-publish` no requieren credenciales AWS. También puedes
ejecutar Terraform directamente desde Lab IDE y reservar Actions para CI. El
sandbox elimina los recursos al finalizar la sesión; guarda outputs y evidencias
fuera de AWS antes de que expire.
