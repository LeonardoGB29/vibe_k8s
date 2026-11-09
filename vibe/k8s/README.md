# Entornos Kubernetes de VIBE

Los overlays comparten los microservicios de `base` y cambian el tamaño y la base de
datos de cada entorno. En AWS **cada entorno corre en su propio clúster k3s** (con su
ELB, buckets, rol de nodos y, en staging y producción, su RDS); el namespace sigue
distinto por convención y para poder leer los recursos sin confusión.

| Entorno | Rol | Overlay | Namespace | Clúster AWS (por defecto) | Base de datos | Autoescalado (techo) |
|---|---|---|---|---|---|---|
| Pruebas | CI y kind local | `overlays/test` | `vibe` | kind (local o job `test-kind` del CI) | PostgreSQL y SeaweedFS/MinIO locales | réplicas del CI |
| Desarrollo | comprobar que compila y no se rompe nada | `overlays/desarrollo` | `vibe` | 1 solo nodo, sin agentes (2 vCPU; escalable) | PostgreSQL local en el clúster | APIs 1–2 réplicas; worker (KEDA) hasta 2 |
| Staging | pruebas de carga | `overlays/staging` | `vibe-staging` | 1 servidor + 2 agentes (6 vCPU) | RDS PostgreSQL Single-AZ | APIs 2–5 réplicas; worker hasta 5 |
| Producción | referencia | `overlays/produccion` | `vibe-produccion` | 1 servidor + 3 agentes (8 vCPU) | RDS PostgreSQL Multi-AZ | APIs 2–8 (stream-api 2–10); worker hasta 8 |

El número de agentes se cambia con `bash aws/scale-aws.sh <entorno> <n>` (escalado horizontal; las imágenes vienen de GHCR y cualquier nodo nuevo las descarga).
Staging y producción no incluyen el StatefulSet de PostgreSQL: los servicios leen
`DATABASE_URL` del Secret `vibe-secrets` de su namespace.

## Cómo se crean `vibe-config` y `vibe-secrets`

No están en Git. Los crea `aws/cluster-init.sh` en el clúster del entorno cuando se
ejecuta `bash aws/deploy-aws.sh <entorno>`:

- `vibe-config`: región, buckets S3 del entorno, cola, bitrates y `MINIO_AUTH=instance-role`.
- `vibe-secrets`: en desarrollo, una contraseña de PostgreSQL generada al azar; en
  staging y producción, la `DATABASE_URL` del RDS, que `deploy-aws.sh` guarda antes como
  SecureString en SSM (`/vibe-<entorno>/database-url`) y que solo puede leer el rol de
  los nodos de ese entorno.

**Acceso a S3 sin claves en Secrets.** Con `MINIO_AUTH=instance-role` los servicios crean
su cliente S3 con el proveedor de credenciales del rol de la EC2 (IMDSv2): son
credenciales **temporales que el propio cliente renueva** antes de que caduquen, así que
no hay claves ni tokens copiados a ningún Secret, nada caduca ni se puede filtrar desde el
repositorio. Para que los pods lleguen al servicio de metadatos, los nodos tienen
`http_put_response_hop_limit = 2` (Terraform, módulo `k3s-cluster`). Compromiso: todos los
pods del clúster comparten la identidad del nodo, por eso el rol (`modules/node-iam`) solo
permite leer y escribir los dos buckets del entorno. En local (kind) se siguen usando las
claves estáticas de MinIO (`MINIO_AUTH` por defecto es `static`).

**Pendiente:** la `DATABASE_URL` usa el usuario administrador de RDS (falta un rol
PostgreSQL restringido para la aplicación).

## Renderizar o desplegar

```bash
kubectl kustomize overlays/test
kubectl kustomize overlays/desarrollo
kubectl kustomize overlays/staging
kubectl kustomize overlays/produccion
```

Para levantar un entorno completo en AWS usa `bash aws/deploy-aws.sh <entorno>` (o
`make aws-up ENV=<entorno>`); no apliques los overlays a mano en un clúster sin
inicializar.

## Despliegue de nuevas versiones (GitHub Actions)

`deploy.yml` recibe el **SHA completo del commit** y el entorno de destino
(`desarrollo`, `staging` o `produccion`). Comprueba que las imágenes `sha-<SHA>` existen en
GHCR, que el servidor del entorno (`vibe-<entorno>-k3s-server`) está encendido y Online
en SSM, y ejecuta `aws/deploy-ghcr.sh` en él: fija las imágenes con el transformador
`images:` de kustomize, aplica el overlay, espera los rollouts, comprueba la salud y, si algo
falla, restaura la revisión anterior (`rollout undo`). Solo desarrollo se despliega solo
(push a `develop`); staging y producción se lanzan a mano. El clúster del entorno debe
existir. La versión de KEDA está en `KEDA_VERSION` (la usan el CI y `cluster-init.sh`).

En CI se renderizan y validan los cuatro overlays con kubeconform, y `test` se despliega
en kind con pruebas de humo. Terraform valida los directorios de desarrollo, staging,
producción, `account` y `bootstrap`.
