# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      nombres de buckets S3 raw y hls
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
modules/monitoring/   dashboard CloudWatch, alarmas EC2/ELB y SNS opcional
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

## CloudWatch

El entorno crea un dashboard y alarmas para `StatusCheckFailed` y CPU de cada
EC2, y para hosts no saludables, cantidad baja de hosts sanos, latencia y
respuestas HTTP 5xx del Classic ELB. Las métricas EC2/ELB las publica AWS sin
instalar agentes. El dashboard se muestra como `cloudwatch_dashboard_url` al
terminar Terraform/deploy.

Para recibir correo, establece `VIBE_ALERT_EMAIL=tu@correo` antes de ejecutar
`bash aws/deploy-sandbox.sh`; SNS enviará un correo de confirmación que hay que
aceptar. Sin esa variable, las alarmas quedan visibles en CloudWatch pero no
envían notificaciones. CPU alta se define como >=85% durante 15 minutos;
latencia ELB como >2 s durante 15 minutos; 5 o más respuestas 5xx en un periodo
de 5 minutos disparan la alarma.

Memoria, logs de sistema y logs de pods no se envían aún a CloudWatch. Para eso
se requiere instalar CloudWatch Agent/Fluent Bit y conceder permisos IAM al rol
de las EC2; el perfil de AWS Academy es precreado y este Terraform no lo modifica.

## GitHub Actions y credenciales

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales temporales del sandbox; renovarlas cada sesión solo si se ejecutan los workflows `terraform` o `deploy` |
| Variable | `TF_STATE_BUCKET` | `vibe-tfstate-<ACCOUNT_ID>` |

Los workflows `ci` y `image-publish` no requieren credenciales AWS. También puedes
ejecutar Terraform directamente desde Lab IDE y reservar Actions para CI. El
sandbox elimina los recursos al finalizar la sesión; guarda outputs y evidencias
fuera de AWS antes de que expire.
