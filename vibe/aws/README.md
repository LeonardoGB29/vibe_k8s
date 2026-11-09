# VIBE en AWS

Hay tres entornos, cada uno con su propio clúster k3s, Classic ELB, buckets S3, rol de
nodos y monitoreo, en la región asignada a la cuenta (`us-east-2`):

| Entorno | Rol | Nodos (por defecto) | vCPU | Autoescalado (techo) | Base de datos | USD/día aprox. (24/7) |
|---|---|---|---:|---|---|---:|
| `desarrollo` | comprobar que compila y que no se rompe nada | **1 servidor `c7i-flex.large`, sin agentes** | 2 | APIs 1–2, worker hasta 2 | PostgreSQL en el clúster | 2,82 |
| `staging` | pruebas de carga | 1 servidor + 2 agentes `t3.small` (se escala a demanda) | 6 | APIs 2–5, worker hasta 5 | RDS Single-AZ | 4,67 |
| `produccion` | referencia | 1 servidor + 3 agentes | 8 | APIs 2–8 (stream-api 2–10), worker hasta 8 | RDS Multi-AZ | 5,85 |

El cómputo se ajusta al rol de cada entorno cambiando el **número de agentes**
(`bash aws/scale-aws.sh <entorno> <n>`, ver «Escalar»): cada agente cuesta ≈0,67 USD/día, y
el servidor, que es lo caro, no cambia. Los discos EBS gp2 son de 20 GB (servidor) y 15 GB
(cada agente). Los nodos se administran con SSM Session Manager: no hay SSH ni claves
`.pem`. El detalle de Terraform, el pipeline CI/CD y las variables de GitHub están en
[terraform/README.md](../terraform/README.md).

**Costo:** con las EC2 apagadas un entorno cuesta ~0,85 USD/día (ELB, discos y alarmas
siguen cobrando). Levanta staging y producción solo cuando los necesites y comprueba la
cuota de vCPU de EC2 (los tres juntos suman 16). El guardián de créditos
(`terraform/account`) pausa EC2 y RDS con la etiqueta `Project=vibe` cuando los créditos
bajan del umbral.

## 1. Preparar la cuenta (una sola vez)

```bash
export AWS_PROFILE=<tu perfil>                 # sesión iniciada con `aws login`
VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh
```

Crea el bucket del state de Terraform, el guardián de créditos y el usuario IAM
`github-vibe-deploy` que usa GitHub Actions (sin clave: se genera a mano, ver
[terraform/README.md](../terraform/README.md#github-actions-y-credenciales)). Pide
escribir `continuar` antes de crear nada. Necesita `aws` y `terraform`; si ejecutas
también `deploy-aws.sh` necesitas `jq`.

## 2. Desplegar un entorno

```bash
bash aws/deploy-aws.sh [desarrollo|staging|produccion]    # o: make aws-up ENV=staging
```

Antes de pedir confirmación busca en GHCR las imágenes publicadas por el CI (las del commit
más reciente de tu historial que tenga las 5; se puede forzar con `VIBE_IMAGE_TAG=sha-<commit>`)
y las muestra. Solicita escribir `desplegar`. Crea/configura los tres buckets del entorno
con AWS CLI, aplica Terraform (EC2 del clúster, ELB, IAM de los nodos, CloudWatch y, en
staging y producción, RDS), guarda la `DATABASE_URL` del RDS en SSM, empaqueta la
aplicación, la instala en el servidor por SSM (`cluster-init.sh`, con el overlay del
entorno), comprueba `/`, `/api/stats` y `/api/tracks` y muestra la URL pública. El número
de agentes lo marca `agent_count` de Terraform (0 en desarrollo; el script se adapta).

Si Terraform no está instalado, el script descarga la versión `TERRAFORM_VERSION`
(1.16.6 por defecto) desde HashiCorp, verifica su SHA-256 y la instala en
`~/.local/bin` (Linux x86_64/ARM64, requiere `python3`).

`cluster-init.sh` instala Traefik (chart 41.6.0, NodePort 30080) y KEDA (la versión está en
`k8s/KEDA_VERSION`) y despliega la aplicación con `deploy-ghcr.sh`, el mismo script del CD:
**no construye imágenes en el servidor**, las descarga de GHCR (paquetes públicos). Así
cualquier nodo que se añada después puede ejecutarlas y el servidor no necesita memoria
extra para compilar. `distribute-ssm.sh` solo lo usa la demo de rolling update.

## Escalar

```bash
bash aws/scale-aws.sh staging 4        # o: make aws-scale ENV=staging AGENTS=4
bash aws/scale-aws.sh staging 1        # al terminar: vacía los nodos que sobran y los elimina
```

Pide escribir `escalar`, aplica Terraform con el nuevo `agent_count`, espera a que los nodos
estén `Ready` y muestra dónde quedaron los pods. Es la forma de dar a staging la capacidad
de una prueba de carga sin pagar esa capacidad todo el tiempo.

## 3. Desplegar nuevas versiones

Un cambio sube de entorno con PRs entre ramas: `feature/*` → `develop` (desarrollo) →
`staging` (staging, donde se hacen las pruebas de carga a mano) → `main` (producción, con
aprobación). Cada merge despliega en el entorno de su rama si el CI pasa (variable de
repositorio `AUTO_DEPLOY=true`); staging y producción se levantan a demanda
(`make aws-up ENV=staging`) y, si están apagados, el merge no falla: avisa y no despliega. También
se puede lanzar a mano el workflow `deploy` con el SHA completo de un commit. Ver
[terraform/README.md](../terraform/README.md#pipeline-cicd-un-cambio-sube-de-entorno-con-pr).

Para repetir las pruebas medidas y guardar evidencia, ver
[DEMONSTRATIONS.md](DEMONSTRATIONS.md). Los PVC locales no dan recuperación de
PostgreSQL/Redis en otro nodo, y la cola BLPOP no recupera sola un trabajo
interrumpido.

## 4. Seguridad de la infraestructura

Terraform exige IMDSv2 y cifra los discos; los nodos no tienen puertos de entrada
públicos. El ELB HTTP público es intencional para la demo. Los buckets se
configuran con bloqueo de acceso público, SSE-S3 y política solo-TLS (Trivy no
inspecciona esas llamadas de AWS CLI). Excepciones IaC temporales: `AWS-0053`
(ELB público), `AWS-0104` (salida a Internet para paquetes e imágenes, sin
endpoints privados) y `AWS-0095` (tema SNS del guardián de créditos sin cifrar:
solo lleva avisos de saldo y CloudWatch no puede publicar con la clave gestionada),
todas con vencimiento el 27 de abril de 2027; al vencer vuelven a requerir revisión.

## 5. CloudWatch

Terraform crea en cada entorno el dashboard `vibe-<entorno>-operations` y alarmas de EC2 y ELB.
Para recibir avisos por correo, antes de desplegar:

```bash
export VIBE_ALERT_EMAIL="tu-correo@example.com"
bash aws/deploy-aws.sh
```

Confirma la suscripción SNS desde el correo que envía AWS. Las métricas del
balanceador necesitan tráfico para mostrar series. El rol de los nodos ya incluye
`CloudWatchAgentServerPolicy`; falta instalar CloudWatch Agent/Fluent Bit para
memoria y logs de sistema y pods.

## 6. Evidencias y limpieza

Exporta resultados, capturas y código a un lugar fuera de AWS. Los recursos no
caducan solos: `make aws-down ENV=<entorno>` (`bash aws/destroy-aws.sh <entorno>`)
ejecuta `terraform destroy` de ese entorno, borra su parámetro `database-url` de SSM y
conserva los buckets S3.
