# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      nombres de buckets S3 raw y hls
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
modules/monitoring/   dashboard CloudWatch, alarmas EC2/ELB y SNS opcional
envs/desarrollo/      composicion del entorno desarrollo en AWS
envs/staging/         wrapper RDS Single-AZ; reutiliza VPC y nodos del entorno desarrollo
envs/produccion/         wrapper RDS Multi-AZ; reutiliza VPC y nodos del entorno desarrollo
```

`test` no usa Terraform: es un cluster kind (`make up`, o el job `test-kind` del CI).
Staging y producción tienen configuraciones y estados separados, pero
reutilizan la VPC y el security group de nodos K3s de `desarrollo`. Esta es una
decisión de costo/cuota del Learner Lab, no aislamiento equivalente a cuentas o
clusters independientes. Los wrappers nuevos aprovisionan RDS; no crean otros
clusters EC2.

## Despliegue en AWS Academy

```bash
cd aws
bash deploy-sandbox.sh
```

El script crea/configura los buckets con AWS CLI y usa Terraform para el resto
de la infraestructura. AWS Academy deniega `s3:GetBucketObjectLockConfiguration`,
que el proveedor AWS de Terraform requiere al leer un recurso `aws_s3_bucket`;
por eso el state y los buckets de audio no se administran como recursos Terraform.

## Staging y producción (RDS)

Los dos wrappers llaman al mismo módulo `modules/rds-postgres` y guardan el state
en objetos S3 separados:

| Entorno | RDS | Retención | Clase inicial | State |
|---|---|---:|---|---|
| `staging` | PostgreSQL Single-AZ | 1 día | `db.t3.micro` | `staging/terraform.tfstate` |
| `produccion` | PostgreSQL Multi-AZ | 3 días | `db.t3.micro` | `produccion/terraform.tfstate` |

Ambos usan 20 GiB gp2, crecimiento máximo de 30 GiB, acceso privado y permiten
conexiones TCP/5432 únicamente desde `vibe-desarrollo-nodes`. Requieren que la
infraestructura de `desarrollo` ya exista en la misma cuenta/VPC. Las clases y
la versión predeterminadas se basan en las opciones que el Learner Lab devolvió
para PostgreSQL en `us-east-1`; AWS todavía puede denegar la creación por
permisos, cuotas o presupuesto.

Para inicializar un wrapper, copia `backend.hcl.example` a `backend.hcl` y usa el
bucket de state existente. Por ejemplo:

```bash
cd vibe/terraform/envs/staging
cp backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Usa los mismos pasos desde `envs/produccion` solo después de destruir
staging si el presupuesto restante lo requiere. `terraform destroy` elimina la
instancia y omite el snapshot final porque son entornos de demostración. El
password administrador se genera automáticamente y queda dentro del state S3
cifrado. `terraform output -raw db_password` lo revela en pantalla; úsalo solo
para el bootstrap administrativo, nunca como credencial de la aplicación, y no
guardes su salida en Git. Falta automatizar la creación de un rol PostgreSQL
restringido para la app y su Secret. No se ejecutó `terraform apply` durante
estos cambios.

Estos wrappers aprovisionan solamente la base RDS. Los overlays Kubernetes
`staging` y `produccion` despliegan los microservicios en namespaces separados y
omiten el PostgreSQL local. Antes del despliegue, cada namespace debe tener un
Secret `vibe-secrets` con la `DATABASE_URL` del usuario PostgreSQL de aplicación
restringido y las credenciales S3 requeridas. El workflow manual `deploy.yml`
permite seleccionar el entorno y el SHA; reutiliza el clúster K3s de desarrollo.
La creación automática del usuario de aplicación/Secret y la prueba de failover
de RDS todavía quedan pendientes.

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
| Secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales temporales del sandbox; renovarlas por sesión en el Environment usado por `terraform` o `deploy` |
| Variable | `TF_STATE_BUCKET` | `vibe-tfstate-<ACCOUNT_ID>` |

Crear los GitHub Environments `desarrollo`, `staging` y `produccion`, con esos
secretos temporales y la variable `TF_STATE_BUCKET` en cada uno. Los workflows
`terraform.yml` y `deploy.yml` permiten elegir el entorno; staging/producción
requieren que desarrollo exista porque comparten su clúster/VPC. Los workflows
`ci` e `image-publish` no requieren credenciales AWS. El sandbox elimina los
recursos al finalizar la sesión; guarda outputs y evidencias fuera de AWS antes
de que expire.
