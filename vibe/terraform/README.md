# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
account/              recursos de cuenta: guardian de creditos (Lambda) y usuario IAM de CI (OIDC opcional)
modules/node-iam/     rol e instance profile de los nodos (SSM, CloudWatch Agent, buckets)
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      nombres de buckets S3 raw y hls
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
modules/monitoring/   dashboard CloudWatch, alarmas EC2/ELB y SNS opcional
envs/desarrollo/      entorno basico para pruebas de codigo (1 servidor + 1 agente)
envs/staging/         clúster k3s propio (1 servidor + 2 agentes, pruebas de carga) + RDS Single-AZ
envs/produccion/      clúster k3s propio (1 servidor + 3 agentes) + RDS Multi-AZ
```

`test` no usa Terraform: es un cluster kind (`make up`, o el job `test-kind` del CI).
Cada entorno (`desarrollo`, `staging`, `produccion`) tiene su propio estado de
Terraform, clúster k3s, Classic ELB, security groups, rol de nodos, buckets S3,
dashboard CloudWatch y (staging/producción) RDS. Lo único que se comparte es la
VPC predeterminada de la cuenta: el aislamiento es por security group, no por
VPC.

| Entorno | Rol | Nodos (por defecto) | vCPU | RDS | USD/día aprox. (24/7) |
|---|---|---|---:|---|---:|
| `desarrollo` | pruebas de código | 1 servidor `t3.medium` + 1 agente `t3.small` | 4 | no (PostgreSQL en el clúster) | 2,45 |
| `staging` | pruebas de carga | 1 servidor + 2 agentes | 6 | Single-AZ `db.t3.micro` | 3,63 |
| `produccion` | referencia | 1 servidor + 3 agentes | 8 | Multi-AZ `db.t3.micro` | 4,81 |

Los tres a la vez suman 18 vCPU y ≈10,9 USD/día. **Comprueba la cuota de EC2 antes de
desplegar** (`aws service-quotas get-service-quota --region us-east-2 --service-code ec2
--quota-code L-1216C47A`; el 08/11/2026 estaba en 8 vCPU en esta cuenta, ajustable con una solicitud en Service Quotas) y levanta staging o producción solo
cuando los necesites. Se puede bajar el tamaño con `-var=agent_count=N`. El guardián de
créditos (abajo) pausa lo que tenga la etiqueta `Project=vibe` si el saldo baja del umbral.

## Despliegue en AWS (región us-east-2)

Primero, **una sola vez**, prepara la cuenta (bucket del state, guardián de
créditos y el usuario IAM de CI para GitHub Actions):

```bash
export AWS_PROFILE=<tu perfil>            # sesión iniciada con `aws login`
VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh
```

Después, un entorno (por defecto `desarrollo`, ≈2,45 USD/día encendido):

```bash
bash aws/deploy-aws.sh [desarrollo|staging|produccion]   # o: make aws-up ENV=staging
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
conexiones TCP/5432 únicamente desde los nodos de su propio entorno
(`vibe-staging-nodes` / `vibe-produccion-nodes`). Ya no dependen de `desarrollo`. Las clases y
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

Los mismos pasos valen para `envs/produccion`. Cada entorno tiene su propio clúster,
así que pueden coexistir si la cuota de vCPU y los créditos lo permiten. `terraform
destroy` elimina la instancia y omite el snapshot final porque son entornos de
demostración. El password administrador se genera automáticamente y queda dentro del
state S3 cifrado. `terraform output -raw db_password` lo revela en pantalla; úsalo solo
para el bootstrap administrativo y no guardes su salida en Git. Falta crear un rol
PostgreSQL restringido para la aplicación. Estos entornos todavía no se han aplicado en
la cuenta actual.

Para levantar un entorno completo (infraestructura + clúster + app):

```bash
bash aws/deploy-aws.sh staging      # o: make aws-up ENV=staging
```

El script aplica Terraform, guarda la `DATABASE_URL` del RDS como SecureString en
SSM (`/vibe-<entorno>/database-url`, legible solo por el rol de los nodos de ese
entorno) y ejecuta `cluster-init.sh` en el servidor con el overlay del entorno
(namespaces `vibe-staging` / `vibe-produccion`, sin PostgreSQL local). El workflow
`deploy.yml` despliega nuevas versiones en el clúster del entorno elegido, que debe
existir y estar encendido. Para destruir: `bash aws/destroy-aws.sh staging`.

**Pendiente:** la `DATABASE_URL` usa el usuario administrador de RDS; falta crear un
rol PostgreSQL restringido para la app. Tampoco se ha probado el failover de RDS.

## Decisiones

- **State:** S3 con versionado, cifrado, bloqueo (`use_lockfile`) y solo TLS. Un state por entorno (`desarrollo/terraform.tfstate`).
- **Minimo privilegio:** unico puerto publico el 80 del ELB; los nodos solo reciben el NodePort desde el ELB y trafico interno; sin SSH (SSM). El token de k3s sale de `random_id` y se guarda en SSM SecureString, no en el user-data ni en Git. IMDSv2 obligatorio, discos cifrados.
  Los nodos usan el rol `vibe-<entorno>-node` (`modules/node-iam`), creado por Terraform con SSM, CloudWatch Agent y acceso solo a los buckets de audio del entorno.
- **Reproducibilidad:** versiones fijas de k3s, de providers (`~>`) y de Terraform (`>= 1.10`), `.terraform.lock.hcl` versionado, AMI ignorada tras la creacion (`ignore_changes`) para que un plan posterior no recree nodos.
- **Idempotencia:** `terraform plan` sin cambios debe salir vacio. KEDA y la aplicacion no estan en Terraform: las aplica `aws/cluster-init.sh` (`kubectl apply -k k8s/overlays/<entorno>`).

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
push develop ─► publica imagenes sha-<SHA> en GHCR ─► deploy AUTOMATICO a DESARROLLO
push main ───► publica imagenes sha-<SHA> en GHCR (no despliega)
manual: Actions > deploy > Run workflow (commit_sha + entorno) ─► STAGING / PRODUCCION
cada despliegue: comprueba imagenes/servidor/SSM ─► aplica ─► salud ─► rollback si falla
diario: terraform-drift.yml compara el codigo con la infraestructura real (requiere OIDC)
```

- **Solo desarrollo se despliega solo.** Cada entorno tiene su propio clúster y los de
  staging y producción solo se encienden a demanda (cuestan dinero y cuota de CPU), así
  que se despliegan a mano con el mismo SHA que ya pasó el CI y está publicado en GHCR:
  *Actions → deploy → Run workflow*. Antes hay que levantar el entorno con
  `make aws-up ENV=staging` (o `produccion`) y destruirlo al terminar con `make aws-down ENV=...`.
- **Activación del automático:** corre solo si la variable de *repositorio* `AUTO_DEPLOY`
  vale `true` (ponla cuando el clúster de desarrollo exista y esté encendido; así un push no
  falla mientras la infraestructura está apagada). `DRIFT_CHECK=true` activa la detección de deriva.
- **Aprobación humana:** configura *Required reviewers* en los Environments `staging` y
  `produccion`: el despliegue manual espera ahí la aprobación de una persona.
- **Infraestructura:** `terraform.yml` sigue siendo manual (crear/destruir recursos cuesta
  dinero); su `plan` se publica en el resumen del job para revisarlo.
- Los paquetes de GHCR deben ser públicos para que los nodos descarguen las imágenes.
- Un solo despliegue a la vez **por entorno** (`deploy-<entorno>`); los clústeres son independientes.

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
entorno en `confirm_destroy` (ese workflow requiere OIDC y no se usa en esta cuenta).
Configura *required reviewers* en los Environments `staging` y `produccion` para tener
una aprobación humana antes de desplegar.
La versión de KEDA se fija en `vibe/k8s/KEDA_VERSION` (la usan el CI y
`aws/cluster-init.sh`). `make aws-down ENV=<entorno>` destruye un entorno con
`aws/destroy-aws.sh <entorno>` y conserva los buckets S3.

Los GitHub Environments `desarrollo`, `staging` y `produccion` ya existen; cada uno
necesita los dos secretos y la variable de la tabla anterior. `deploy.yml` permite
elegir el entorno, y el clúster de ese entorno debe existir y estar encendido. Los
jobs `ci` e `image-publish` no requieren credenciales AWS. Los recursos no caducan
solos: destrúyelos cuando no los uses, y guarda outputs y evidencias fuera de AWS
antes de que se agoten los créditos.
