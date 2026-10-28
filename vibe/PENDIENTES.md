# Pendientes · integración Terraform + CI

## Para revisar

- [ ] Volver a ejecutar CI en `main` y dejar verdes los checks requeridos. El último escaneo IaC falló por hallazgos Trivy `HIGH`/`CRITICAL`; documentar excepciones del sandbox antes de cambiar el gate.
- [x] Actualizado `.github/workflows/ci.yml`: `test-kind` usa el overlay `ci` y Trivy escanea Terraform activo. Renderizado localmente; falta ejecutar el workflow en GitHub.
- [x] `test-kind`: overlay `ci` con una réplica por microservicio, usado por el workflow para reducir consumo del runner.
- [x] `kubectl kustomize k8s/overlays/test` y `.../desarrollo` renderizan localmente; `desarrollo` conserva `maxReplicaCount: 8`.
- [ ] Cambio de orden en el despliegue: las APIs ya no esperan a Postgres/MinIO antes de crearse. Pendiente comprobar reinicios con un despliegue real; las APIs reintentan conexión a Postgres al iniciar.
- [ ] Versión de k3s (`v1.31.4+k3s1`): confirmar que existe, o cambiarla con `-var k3s_version=...`.
- [x] Confirmado sandbox AWS Academy disponible: región `us-east-1`, `LabInstanceProfile`/`LabRole` y `vockey` precreados, máximo de 9 EC2.
- [ ] Revisar cuota/costo del sandbox y confirmar que hay espacio para cuatro EC2 (20 GB y 15 GB gp2, dentro de los límites publicados).
- [ ] `terraform plan` sin cambios tras el primer `apply` (idempotencia).

Estado de ejecución: el PR #1 ya está integrado en `main`. El despliegue usa
credenciales temporales del Lab IDE; el sandbox borra recursos y estado al acabar
la sesión.

## Por hacer

### GitHub
- [x] Integrar el PR #1 `integracion_terraform` → `main`.
- [ ] Revisar los cinco PRs de Dependabot (#2–#6); cada uno actualiza una GitHub Action y debe pasar CI antes de integrarse.
- [ ] Confirmar permisos de GitHub; AWS se opera desde Lab IDE, no con secretos persistentes de Actions.
- [ ] Crear el Environment `desarrollo`:
  - Para ejecutar `terraform`/`deploy` desde Actions, actualizar los tres secretos temporales por sesión; nunca subirlos al repositorio.
  - Variable: `TF_STATE_BUCKET`.
- [ ] Branch protection en `main`: exigir que el CI pase.

### Seguridad y escaneo IaC
- [x] Confirmado: Terraform y overlays actuales son activos; `aws/cloudformation.yaml` y `k8s/legacy` son referencia histórica. Trivy escanea Terraform vigente.
- [x] Documentada la salida global temporal (`AWS-0104`): necesaria para descargas en el sandbox sin endpoints privados; no hay entrada pública en los nodos.
- [x] Documentadas las excepciones: SSE-S3 por permisos KMS insuficientes y ELB HTTP público requerido por la demo. No se habilita SSE-KMS.
- [x] Imágenes de los cinco microservicios ejecutan como usuario sin privilegios (`DS-0002`); archivos de la app son legibles y temporales del worker/upload van en `/tmp`.
- [x] Añadido `runAsNonRoot`, UID/GID no privilegiado y seccomp RuntimeDefault en los cinco workloads de aplicación. `readOnlyRootFilesystem` queda pendiente hasta validarlo en despliegue.
- [x] CloudFormation marcado como legado no soportado y fuera del escaneo activo; Terraform vigente exige IMDSv2 y cifra EBS.
- [ ] Volver a ejecutar Trivy/Checkov en GitHub y comprobar que las excepciones locales con vencimiento se aplican, los hallazgos quedan visibles en el reporte y otros `HIGH`/`CRITICAL` siguen bloqueando el gate.

### Terraform
- [ ] Crear en GitHub el Environment `desarrollo`, configurar `TF_STATE_BUCKET` y actualizar `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` en cada sesión.
- [ ] Ejecutar `terraform/bootstrap` desde Lab IDE y anotar el bucket de state. Repetir en cada sesión porque el sandbox elimina también el estado remoto.
- [ ] En Actions, ejecutar `terraform.yml` con `action=plan`, revisar el plan y luego lanzar `action=apply` en una ejecución separada.
- [ ] Entrar al servidor con SSM y ejecutar `cluster-init.sh` usando `LabInstanceProfile`.
- [ ] Verificar la app por la URL del ELB y borrar el stack viejo de CloudFormation si ya no se necesita.
- [ ] Probar `deploy.yml` con el SHA de una imagen publicada en GHCR; comprobar permisos SSM y visibilidad del paquete para EC2.
- [ ] Ejecutar `action=destroy` al terminar la práctica si se requiere borrado controlado antes de que venza la sesión.

### Mejoras siguientes
- [x] Añadido workflow manual `deploy.yml` para el despliegue por SSM. Falta validar permisos y ejecución real en AWS.
- [x] Añadida publicación de imágenes a GHCR con tags por commit en CI. Requiere configurar los paquetes como públicos para que EC2 pueda hacer pull sin credenciales.
- [ ] Secretos de la app (Postgres `vibe/vibe`) fuera de Git: SSM Parameter Store o SOPS.
- [x] Añadido escaneo Trivy/Checkov y TFLint al CI; confirmar que el workflow queda verde.
- [x] Añadido Dependabot para Actions e imágenes de contenedor. KEDA/k3s se mantienen en los manifiestos y requieren revisión manual.
- [ ] Opcional: Argo CD para GitOps de la parte Kubernetes.

### Base de datos y resiliencia
- [x] AWS genera una contraseña PostgreSQL aleatoria en la primera inicialización, la persiste en el Secret `vibe-secrets` de Kubernetes y pasa `DATABASE_URL` desde ese Secret. Los overlays locales conservan credenciales solo para pruebas; aún falta migrar el Secret persistido a SSM/Secrets Manager.
- [x] Limitar pools SQL: catálogo 3+1, upload 2+1, worker 1+0. Con el HPA/KEDA actuales (hasta 8 por servicio) presupuestar hasta 48 conexiones de aplicación; validar ese máximo contra la capacidad real de PostgreSQL antes de subir autoscaling.
- [ ] Medir latencia/espera de consultas y saturación antes de elegir escalado vertical o servicio administrado.
- [ ] Evaluar RDS PostgreSQL Single-AZ (el sandbox no permite Multi-AZ; clases nano–medium) frente al PostgreSQL del clúster, incluyendo costo y permisos.
- [ ] Definir backups automatizados y probar restauración; PVC local no ofrece recuperación entre nodos.
- [ ] Hacer durable y reintentable la cola de transcodificación (ACK tras completar, reintentos e idempotencia).
- [ ] Instalar métricas/alertas en AWS.
- [x] ServiceMonitor local actualizado para catalog-api, upload-api, stream-api y worker; validar instalación AWS con Prometheus real.
