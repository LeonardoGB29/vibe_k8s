# Terraform · VIBE

```
bootstrap/            nombre del bucket S3 del state
account/              recursos de cuenta: guardian de creditos (Lambda) y usuario IAM de CI (OIDC opcional)
modules/node-iam/     rol e instance profile de los nodos (SSM, CloudWatch Agent, buckets)
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      nombres de buckets S3 raw y hls
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
modules/monitoring/   dashboard CloudWatch, alarmas EC2/ELB y SNS opcional
envs/desarrollo/      pruebas de codigo: 1 solo nodo (agent_count = 0), escalable con aws/scale-aws.sh
envs/staging/         clúster k3s propio (1 servidor + 2 agentes, pruebas de carga) + RDS Single-AZ
envs/produccion/      clúster k3s propio (1 servidor + 3 agentes) + RDS Multi-AZ
```

`test` no usa Terraform: es un cluster kind (`make up`, o el job `test-kind` del CI).
Cada entorno (`desarrollo`, `staging`, `produccion`) tiene su propio estado de
Terraform, clúster k3s, Classic ELB, security groups, rol de nodos, buckets S3,
dashboard CloudWatch y (staging/producción) RDS. Lo único que se comparte es la
VPC predeterminada de la cuenta: el aislamiento es por security group, no por
VPC.

Cada entorno tiene un **rol** y el cómputo que ese rol necesita. Los nodos son del mismo tipo
en los tres (servidor `c7i-flex.large`, agentes `t3.small`), así que lo que cambia es el
**número de agentes**: se añaden o se quitan sin tocar el resto (escalado horizontal).

| Entorno | Rol | Nodos (por defecto) | vCPU | RDS | USD/día aprox. (24/7) |
|---|---|---|---:|---|---:|
| `desarrollo` | comprobar que compila y que no se rompe nada | **1 servidor, sin agentes** (el servidor también ejecuta los pods) | 2 | no (PostgreSQL en el clúster) | 2,82 |
| `staging` | pruebas de carga antes de producción | 1 servidor + 2 agentes; **se escala a demanda** | 6 | Single-AZ `db.t3.micro` | 4,67 |
| `produccion` | referencia | 1 servidor + 3 agentes | 8 | Multi-AZ `db.t3.micro` | 5,85 |

Cada agente extra cuesta ≈0,67 USD/día (`t3.small` + IPv4 + disco), mucho menos que el
servidor (≈2 USD/día), por eso el escalado se hace con agentes. Staging usa los mismos tipos
de nodo que producción para que los resultados de carga sean comparables.

Los tres a la vez suman 16 vCPU y ≈13,3 USD/día. **Comprueba la cuota de EC2 antes de
desplegar** (`aws service-quotas get-service-quota --region us-east-2 --service-code ec2
--quota-code L-1216C47A`; el 08/11/2026 estaba en 8 vCPU en esta cuenta, ajustable con una
solicitud en Service Quotas): con 8 caben, por ejemplo, desarrollo (2) + staging (6) o producción sola.
Levanta staging o producción solo cuando los necesites. El guardián de créditos (abajo) pausa lo
que tenga la etiqueta `Project=vibe` si el saldo baja del umbral.

### Escalar horizontalmente

```bash
bash aws/scale-aws.sh staging 4          # o: make aws-scale ENV=staging AGENTS=4
bash aws/scale-aws.sh staging 1          # al terminar la prueba: vacía (drain) y quita los agentes sobrantes
```

Los agentes se unen al servidor con el token de SSM, el ELB los incluye y Kubernetes reparte
los pods; las imágenes se descargan de GHCR, por lo que cualquier nodo nuevo puede ejecutarlas.
HPA (APIs) y KEDA (workers) aprovechan la capacidad nueva hasta el techo de cada overlay. El
script guarda `agent_count` en `envs/<entorno>/agents.auto.tfvars` (ignorado por git) para que un
`apply` local posterior no revierta el tamaño. Subir de 6 a 8 vCPU o más exige que la cuota de EC2 lo permita.

**Tipos de instancia:** el plan gratuito de AWS solo permite tipos «Free Tier eligible»
(en `us-east-2`: `c7i-flex.large`, `m7i-flex.large`, `t3.micro`/`t3.small`, `t4g.micro`/`t4g.small`,
`t8i.micro`/`t8i.small`). Por eso el servidor es un `c7i-flex.large` (2 vCPU, 4 GB; ≈1,03 USD/día más
que un `t3.medium`, que daría `InvalidParameterCombination`) y los agentes son `t3.small`. Si la cuenta
pasa al plan de pago se puede volver a `t3.medium` con `-var=server_instance_type=t3.medium`. Lista
actual: `aws ec2 describe-instance-types --region us-east-2 --filters Name=free-tier-eligible,Values=true`.

## Despliegue en AWS (región us-east-2)

Primero, **una sola vez**, prepara la cuenta (bucket del state, guardián de
créditos y el usuario IAM de CI para GitHub Actions):

```bash
export AWS_PROFILE=<tu perfil>            # sesión iniciada con `aws login`
VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh
```

Después, un entorno (por defecto `desarrollo`, ≈2,82 USD/día encendido):

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

## Pipeline CI/CD: un cambio sube de entorno con PR

```
feature/* ─PR─► develop ─PR─► staging ─PR─► main
                   │             │            │
                   ▼             ▼            ▼
              DESARROLLO      STAGING      PRODUCCIÓN
          (compila y no se   (pruebas de   (aprobación
           rompe nada)        carga a mano) de una persona)
```

Cada PR ejecuta el CI (pruebas, validaciones, escaneos, build de las 5 imágenes y despliegue de
prueba en kind). Al hacer merge, el CI corre en la rama de destino y, si pasa, publica las imágenes
`sha-<SHA>` en GHCR y **despliega ese SHA en el entorno de la rama**:

| Rama | Entorno | Qué se hace antes de promover |
|---|---|---|
| `develop` | desarrollo | comprobar que compila y que no se rompe nada (CI + comprobaciones de salud del despliegue) |
| `staging` | staging | **pruebas de carga manuales** con el visor `k8s-web` (ver abajo) |
| `main` | producción | aprobación de los *Required reviewers* del Environment `produccion` |

- **Orden obligatorio:** el job `promotion-guard` falla si un PR hacia `staging` no viene de `develop` o si un PR
  hacia `main` no viene de `staging`. Márcalo (junto con el CI) como check requerido en las rulesets.
- **Cada despliegue** comprueba que las imágenes existen y que el servidor del entorno está encendido, aplica, comprueba
  la salud y hace rollback automático si falla.
- **Entornos a demanda:** staging y producción se levantan cuando hacen falta (`make aws-up ENV=staging`). Si el clúster
  del entorno está apagado cuando llega el merge, el despliegue termina con un aviso (pestaña *Summary* del run) y no
  pone el CI en rojo; el cambio queda en la rama y se despliega al levantar el entorno
  (*Actions → deploy → Run workflow* con ese SHA).
- **Activación:** el despliegue automático solo corre si la variable de *repositorio* `AUTO_DEPLOY` vale `true`.
- **Se reconstruyen las imágenes en cada rama** (un merge crea un commit nuevo y por tanto un SHA nuevo); el código es el mismo
  que ya pasó por el entorno anterior. Para desplegar exactamente las imágenes de otro SHA usa el workflow `deploy` a mano.
- **Infraestructura:** `terraform.yml` sigue siendo manual (crear/destruir recursos cuesta dinero); su `plan` se publica en
  el resumen del job.
- Los paquetes de GHCR deben ser públicos para que los nodos descarguen las imágenes.
- Un solo despliegue a la vez **por entorno** (`deploy-<entorno>`); los clústeres son independientes.

### Pruebas de carga (solo staging, manuales y didácticas)

El visor `k8s-web` incluye un *Centro de pruebas* que explica cada escenario y lo lanza con k6 contra el balanceador del
entorno. En AWS solo se ofrece en **staging** (en desarrollo y producción muestra un aviso) y solo las pruebas de carga
(carga sostenida, estrés, pico, usuarios fijos, rampa y worker/KEDA); las simulaciones de fallo siguen siendo del clúster
local (kind). Requisitos en tu PC: `k6` (`winget install k6`), AWS CLI con el *Session Manager plugin*, `kubectl` y Python.

```powershell
.\"Conectar VIBE AWS.cmd" staging       # abre http://localhost:8085 con la pestaña «Pruebas»
```

Para ver el escalado mientras corre la prueba, sube agentes antes (`bash aws/scale-aws.sh staging 3`) y bájalos al terminar.
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
