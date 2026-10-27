# Pendientes · integración Terraform + CI

## Para revisar

- [ ] CI verde en el PR (`manifests`, `dockerfiles`, `build`, `terraform`, `test-kind`, `security`). Los overlays renderizan localmente.
- [ ] `test-kind`: si los pods quedan `Pending` por falta de CPU/RAM en el runner, crear un overlay `ci` con 1 réplica.
- [x] `kubectl kustomize k8s/overlays/test` y `.../desarrollo` renderizan localmente; `desarrollo` conserva `maxReplicaCount: 8`.
- [ ] Cambio de orden en el despliegue: las APIs ya no esperan a Postgres/MinIO antes de crearse. Comprobar que no hay reinicios problemáticos.
- [ ] Versión de k3s (`v1.31.4+k3s1`): confirmar que existe, o cambiarla con `-var k3s_version=...`.
- [x] Confirmado sandbox AWS Academy disponible: región `us-east-1`, `LabInstanceProfile`/`LabRole` y `vockey` precreados, máximo de 9 EC2.
- [ ] Revisar cuota/costo del sandbox y confirmar que hay espacio para cuatro EC2 (20 GB y 15 GB gp2, dentro de los límites publicados).
- [ ] `terraform plan` sin cambios tras el primer `apply` (idempotencia).

Estado de ejecución: CI requiere GitHub; el despliegue debe ejecutarse desde Lab
IDE con credenciales temporales. El sandbox borra los recursos al acabar la sesión.

## Por hacer

### GitHub
- [ ] Abrir el PR `integracion_terraform` → `main`.
- [ ] Confirmar permisos de GitHub; AWS se opera desde Lab IDE, no con secretos persistentes de Actions.
- [ ] Crear el Environment `desarrollo`:
  - Para ejecutar `terraform`/`deploy` desde Actions, actualizar los tres secretos temporales por sesión; nunca subirlos al repositorio.
  - Variable: `TF_STATE_BUCKET`.
- [ ] Branch protection en `main`: exigir que el CI pase.

### Terraform
- [ ] Ejecutar `terraform/bootstrap` desde Lab IDE y anotar `state_bucket` mientras dure la sesión.
- [ ] `terraform init -backend-config=backend.hcl` y `apply` en `envs/desarrollo`.
- [ ] Entrar al servidor con SSM y ejecutar `cluster-init.sh` usando `LabInstanceProfile`.
- [ ] Verificar la app por la URL del ELB y borrar el stack viejo de CloudFormation.

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
- [ ] Instalar métricas/alertas en AWS y actualizar ServiceMonitor para los microservicios.
