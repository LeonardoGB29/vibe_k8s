# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
account/              recursos de cuenta: guardian de creditos (Lambda) y roles OIDC de GitHub
modules/node-iam/     rol e instance profile de los nodos (SSM, CloudWatch Agent, buckets)
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
decisión de costo/cuota (límite de 8 vCPU y 100 USD de créditos), no aislamiento equivalente a cuentas o
clusters independientes. Los wrappers nuevos aprovisionan RDS; no crean otros
clusters EC2.

## Despliegue en AWS (región us-east-2)

Primero, **una sola vez**, prepara la cuenta (bucket del state, guardián de
créditos y roles OIDC para GitHub):

```bash
export AWS_PROFILE=<tu perfil>            # sesión iniciada con `aws login`
VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh
```

Después, el entorno desarrollo (≈3,8 USD/día encendido):

```bash
bash aws/deploy-aws.sh                # o: make aws-up
```

El script crea/configura los buckets con AWS CLI y usa Terraform para el resto
de la infraestructura (los buckets no son recursos Terraform:
así el bucket del state existe antes que Terraform).

### Guardián de créditos

`account/` despliega la Lambda `vibe-credit-guard` (cada hora): lee el saldo real
de créditos del plan (`freetier:GetAccountPlanState`) y, si baja de
`stop_below_usd` (20 USD por defecto), **detiene las EC2 y RDS con la etiqueta
`Project=vibe`** y avisa por SNS. Limitaciones: el saldo se actualiza con retraso
(horas), por eso el umbral deja margen; no puede parar el ELB (~0,6 USD/día), que
solo desaparece con `terraform destroy`; las EC2 paradas se reinician a mano y
una RDS parada AWS la reinicia sola a los 7 días (el guardián la vuelve a parar
mientras el saldo siga bajo el umbral). Una alarma avisa si la propia Lambda falla.
Prueba sin riesgo: `terraform apply -var=guard_dry_run=true` solo registra lo que detendría.

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
la versión predeterminadas (`db.t3.micro`, PostgreSQL 16.15) son las que ofrece
`us-east-2`; AWS todavía puede denegar la creación por
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
  Los nodos usan el rol `vibe-<entorno>-node` (`modules/node-iam`), creado por Terraform con SSM, CloudWatch Agent y acceso solo a los buckets de audio del entorno.
- **Reproducibilidad:** versiones fijas de k3s, de providers (`~>`) y de Terraform (`>= 1.10`), `.terraform.lock.hcl` versionado, AMI ignorada tras la creacion (`ignore_changes`) para que un plan posterior no recree nodos.
- **Idempotencia:** `terraform plan` sin cambios debe salir vacio. KEDA y la aplicacion no estan en Terraform: las aplica `aws/cluster-init.sh` (`kubectl apply -k k8s/overlays/desarrollo`).

## CloudWatch

El entorno crea un dashboard y alarmas para `StatusCheckFailed` y CPU de cada
EC2, y para hosts no saludables, cantidad baja de hosts sanos, latencia y
respuestas HTTP 5xx del Classic ELB. Las métricas EC2/ELB las publica AWS sin
instalar agentes. El dashboard se muestra como `cloudwatch_dashboard_url` al
terminar Terraform/deploy.

Para recibir correo, establece `VIBE_ALERT_EMAIL=tu@correo` antes de ejecutar
`bash aws/deploy-aws.sh`; SNS enviará un correo de confirmación que hay que
aceptar. Sin esa variable, las alarmas quedan visibles en CloudWatch pero no
envían notificaciones. CPU alta se define como >=85% durante 15 minutos;
latencia ELB como >2 s durante 15 minutos; 5 o más respuestas 5xx en un periodo
de 5 minutos disparan la alarma.

Memoria, logs de sistema y logs de pods no se envían aún a CloudWatch. Para eso
se requiere instalar CloudWatch Agent/Fluent Bit en los nodos; el rol de las EC2
ya incluye `CloudWatchAgentServerPolicy`.

## Pipeline CI/CD

```
PR / push ──► CI: pruebas, fmt/validate, TFLint, Checkov, Trivy, kubeconform, hadolint,
              build de imagenes y despliegue de prueba en kind
push develop ─► publica imagenes sha-<SHA> en GHCR ─► deploy automatico a DESARROLLO
push main ───► publica imagenes ─► deploy automatico a STAGING ─► (aprobacion) PRODUCCION
                                   mismo SHA en los tres: se promueve el mismo artefacto
cada despliegue: comprueba imagenes/servidor/SSM ─► aplica ─► salud ─► rollback si falla
diario: terraform-drift.yml compara el codigo con la infraestructura real
```

- **Activacion:** el despliegue automatico corre solo si la variable de *repositorio*
  `AUTO_DEPLOY` vale `true` (ponla cuando el cluster de desarrollo exista y esté
  encendido; así un push no falla mientras la infraestructura está apagada).
  `DRIFT_CHECK=true` activa la detección diaria de deriva.
- **Aprobación humana:** configura *Required reviewers* en el Environment `produccion`
  (y en `staging` si quieres) para que el pipeline espere ahí; lo mismo sirve para
  `apply`/`destroy` de `terraform.yml`.
- **Infraestructura:** `terraform.yml` sigue siendo manual (crear/destruir recursos
  cuesta dinero); su `plan` se publica en el resumen del job para revisarlo.
- Los paquetes de GHCR deben ser públicos para que los nodos descarguen las imágenes.
- Un solo despliegue a la vez (`deploy-cluster`), porque los tres entornos comparten cluster.

## GitHub Actions y credenciales

El proyecto AWS prohíbe el proveedor OIDC de GitHub (SCP), así que `deploy.yml` se
autentica con la clave del usuario IAM `github-vibe-deploy` (lo crea `terraform/account`;
permisos mínimos: solo SSM Run Command sobre EC2 `Project=vibe`, subir a `deployment/`
y leer EC2/ELB). La clave **no** está en Terraform ni en el repo: se crea a mano y se
guarda como secreto.

```bash
aws iam create-access-key --user-name github-vibe-deploy --profile <perfil>
```

En **cada** Environment (`desarrollo`, `staging`, `produccion`) de GitHub:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | `AccessKeyId` de la clave |
| Secret | `AWS_SECRET_ACCESS_KEY` | `SecretAccessKey` de la clave |
| Variable | `AWS_REGION` | `us-east-2` |

Rota la clave cada ~90 días (crear la nueva, actualizar los secretos y borrar la vieja con
`aws iam delete-access-key`). Terraform (`terraform.yml` y la detección de deriva) requeriría
OIDC y no se usa en esta cuenta: ejecútalo en local con `aws/deploy-aws.sh`.

`deploy.yml` recibe el **SHA completo del commit** (`commit_sha`); la imagen GHCR
es `sha-<SHA>` (prefijo que añade `docker/metadata-action`). Antes de desplegar
comprueba que las imágenes existen, que el servidor está encendido y Online en SSM;
si el despliegue falla, `deploy-ghcr.sh` restaura la revisión anterior (`rollout undo`).

Para `action=destroy` el workflow `terraform.yml` exige escribir el nombre del
entorno en `confirm_destroy`. Configura además *required reviewers* en cada
GitHub Environment para tener una aprobación humana antes de `apply`/`destroy`.
La versión de KEDA se fija en `vibe/k8s/KEDA_VERSION` (la usan el CI y
`aws/cluster-init.sh`). `make aws-down` destruye el entorno desarrollo con
`aws/destroy-aws.sh`.

Crear los GitHub Environments `desarrollo`, `staging` y `produccion`, con las
variables anteriores en cada uno. Los workflows
`terraform.yml` y `deploy.yml` permiten elegir el entorno; staging/producción
requieren que desarrollo exista porque comparten su clúster/VPC. Los workflows
`ci` e `image-publish` no requieren credenciales AWS. Los recursos no caducan
solos: destrúyelos (`make aws-down`, o `terraform.yml` con `action=destroy`) cuando
no los uses, y guarda outputs y evidencias fuera de AWS antes de que se agoten los créditos.
