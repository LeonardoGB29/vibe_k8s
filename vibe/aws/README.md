# VIBE en AWS

El entorno `desarrollo` corre en la región asignada a la cuenta (`us-east-2`):
cuatro EC2 (`t3.medium` para el servidor k3s + 3 `t3.small` como agentes), un
Classic ELB y buckets S3. Los discos EBS gp2 son de 20 GB (servidor) y 15 GB
(cada agente). Los nodos se administran con SSM Session Manager: no hay SSH ni
claves `.pem`. El detalle de Terraform, el pipeline CI/CD y las variables de
GitHub están en [terraform/README.md](../terraform/README.md).

**Costo aproximado** encendido 24/7: ~3,8 USD/día (~0,85 USD/día con las EC2
apagadas, porque ELB, discos y alarmas siguen cobrando). El guardián de créditos
(`terraform/account`) pausa EC2 y RDS cuando los créditos bajan del umbral.

## 1. Preparar la cuenta (una sola vez)

```bash
export AWS_PROFILE=<tu perfil>                 # sesión iniciada con `aws login`
VIBE_ALERT_EMAIL=tu@correo bash aws/init-account.sh
```

Crea el bucket del state de Terraform, el guardián de créditos y los roles OIDC
de GitHub Actions. Pide escribir `continuar` antes de crear nada.

## 2. Desplegar el entorno desarrollo

```bash
bash aws/deploy-aws.sh          # o: make aws-up
```

Solicita escribir `desplegar`. Crea/configura tres buckets con AWS CLI, aplica
Terraform (cuatro EC2, ELB, IAM de los nodos, CloudWatch), empaqueta la
aplicación, la instala en el servidor por SSM (`cluster-init.sh`), comprueba `/`,
`/api/stats` y `/api/tracks` y muestra la URL pública. Antes de empezar revisa
el espacio libre local, en el servidor y en cada agente.

Si Terraform no está instalado, el script descarga la versión `TERRAFORM_VERSION`
(1.16.6 por defecto) desde HashiCorp, verifica su SHA-256 y la instala en
`~/.local/bin` (Linux x86_64/ARM64, requiere `python3`).

`cluster-init.sh` instala Traefik (chart 41.6.0, NodePort 30080) y KEDA (la
versión está en `k8s/KEDA_VERSION`), construye las imágenes en el servidor y las
distribuye a los agentes con S3 y SSM Run Command (`build-and-load.sh`,
`distribute-ssm.sh`).

## 3. Desplegar nuevas versiones

Con el pipeline: un push a `develop` publica las imágenes y despliega en
desarrollo; `main` despliega en staging y, tras aprobación, en producción
(variable de repositorio `AUTO_DEPLOY=true`). También se puede lanzar a mano el
workflow `deploy` con el SHA completo de un commit. Ver
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
(ELB público) y `AWS-0104` (salida a Internet para paquetes e imágenes, sin
endpoints privados), ambas con vencimiento el 27 de abril de 2027; al vencer
vuelven a requerir revisión.

## 5. CloudWatch

Terraform crea el dashboard `vibe-desarrollo-operations` y alarmas de EC2 y ELB.
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
caducan solos: `make aws-down` (`bash aws/destroy-aws.sh`) ejecuta
`terraform destroy` del entorno desarrollo y conserva los buckets S3.
