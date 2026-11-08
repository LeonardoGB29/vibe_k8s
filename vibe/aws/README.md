# VIBE en AWS

Hay tres entornos, cada uno con su propio clúster k3s, Classic ELB, buckets S3, rol de
nodos y monitoreo, en la región asignada a la cuenta (`us-east-2`):

| Entorno | Nodos (por defecto) | vCPU | Base de datos | USD/día aprox. (24/7) |
|---|---|---:|---|---:|
| `desarrollo` | 1 servidor `t3.medium` + 1 agente `t3.small` | 4 | PostgreSQL en el clúster | 2,45 |
| `staging` | 1 servidor + 2 agentes | 6 | RDS Single-AZ | 3,63 |
| `produccion` | 1 servidor + 3 agentes | 8 | RDS Multi-AZ | 4,81 |

Los discos EBS gp2 son de 20 GB (servidor) y 15 GB (cada agente). Los nodos se
administran con SSM Session Manager: no hay SSH ni claves `.pem`. El detalle de
Terraform, el pipeline CI/CD y las variables de GitHub están en
[terraform/README.md](../terraform/README.md).

**Costo:** con las EC2 apagadas un entorno cuesta ~0,85 USD/día (ELB, discos y alarmas
siguen cobrando). Levanta staging y producción solo cuando los necesites y comprueba la
cuota de vCPU de EC2 (los tres juntos suman 18). El guardián de créditos
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

Solicita escribir `desplegar`. Crea/configura los tres buckets del entorno con AWS CLI,
aplica Terraform (EC2 del clúster, ELB, IAM de los nodos, CloudWatch y, en staging y
producción, RDS), guarda la `DATABASE_URL` del RDS en SSM, empaqueta la aplicación, la
instala en el servidor por SSM (`cluster-init.sh`, con el overlay del entorno), comprueba
`/`, `/api/stats` y `/api/tracks` y muestra la URL pública. Antes de empezar revisa el
espacio libre local, en el servidor y en cada agente. El número de agentes lo marca
`agent_count` de Terraform (el script se adapta al número real).

Si Terraform no está instalado, el script descarga la versión `TERRAFORM_VERSION`
(1.16.6 por defecto) desde HashiCorp, verifica su SHA-256 y la instala en
`~/.local/bin` (Linux x86_64/ARM64, requiere `python3`).

`cluster-init.sh` instala Traefik (chart 41.6.0, NodePort 30080) y KEDA (la
versión está en `k8s/KEDA_VERSION`), construye las imágenes en el servidor y las
distribuye a los agentes con S3 y SSM Run Command (`build-and-load.sh`,
`distribute-ssm.sh`).

## 3. Desplegar nuevas versiones

Con el pipeline: un push a `develop` que pasa el CI publica las imágenes y despliega
solo en desarrollo (variable de repositorio `AUTO_DEPLOY=true`). Staging y producción se
levantan a demanda (`make aws-up ENV=staging`) y se despliegan a mano con el workflow
`deploy` y el SHA completo de un commit, con aprobadores en su Environment. Ver
[terraform/README.md](../terraform/README.md#pipeline-cicd).

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
