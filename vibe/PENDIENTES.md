# Pendientes · integración Terraform + CI

## Para revisar

- [x] Volver a ejecutar CI en `main`: todos los jobs requeridos quedaron verdes en el commit `735b619`.
- [x] Actualizado `.github/workflows/ci.yml`: `test-kind` usa el overlay `ci` y Trivy escanea Terraform activo. Renderizado localmente y CI verde en GitHub para `main` (`735b619`).
- [x] `test-kind`: overlay `ci` con una réplica por microservicio, usado por el workflow para reducir consumo del runner.
- [x] `kubectl kustomize k8s/overlays/test` y `.../desarrollo` renderizan localmente; `desarrollo` conserva `maxReplicaCount: 8`.
- [x] Reinicios graduales de `catalog-api`, `upload-api` y `stream-api` completados en AWS; cada deployment volvió a 2/2 y `/`, `/api/stats` y `/api/tracks` respondieron HTTP 200.
- [x] Prueba de caída/recuperación de Postgres (`vibe/aws/demo.py db`): Postgres volvió a 1/1 en 12,1 s; el streaming HLS tuvo 0/29 errores. `/api/tracks` tuvo 22/29 errores mientras la base estuvo apagada y volvió a HTTP 200 al finalizar. Evidencia en `C:\Users\Michael\vibe-evidence\20261028T070734Z-db`.
- [ ] Validar aparte el arranque de las APIs mientras Postgres todavía no está disponible (orden de despliegue y reintentos de conexión al iniciar).
- [x] Versión de k3s (`v1.31.4+k3s1`): confirmada en el despliegue real del clúster.
- [x] Revisión de cuotas y costo el 28/10/2026: cuatro EC2 activas (8 vCPU) de la cuota de la cuenta; cuota estándar EC2 reportada por Service Quotas: 256 vCPU. Cost Explorer mostró USD 0,319 acumulados del 1 al 29 de octubre para la cuenta (sin filtrar por proyecto/etiquetas; cifra orientativa).
- [x] `terraform plan` sin cambios después del `apply`; comprobado en CloudShell el 28/10/2026.
- [x] Crear y usar `k8s-web/connect-aws-tunnel.ps1` desde Windows; túnel SSM confirmado. `kubectl get nodes` mostró los cuatro nodos `Ready` y todos los pods de `vibe` estaban `Running`/`Ready` el 28/10/2026.

Estado de ejecución: el PR #1 ya está integrado en `main`. Las marcas anteriores corresponden a un despliegue previo en otra cuenta, ya destruida; en la cuenta actual (`us-east-2`) todavía no hay nada desplegado. Para desplegar, ver la sección «Migración a cuenta AWS propia» más abajo y `aws/README.md`.

## Por hacer

### GitHub
- [x] Integrar el PR #1 `integracion_terraform` → `main`.
- [ ] Revisar los PRs de Dependabot abiertos (#2, #3, #4 y #6); sus checks de IaC fallan en las ejecuciones actuales. El PR #5 está cerrado sin merge. Los PRs apuntan a la base `a941331`, anterior al `main` actual (`735b619`); actualizar/revalidar antes de integrar.
- [ ] Confirmar permisos de GitHub (los workflows usan OIDC, sin secretos persistentes).
- [ ] Crear los Environments `desarrollo`, `staging` y `produccion`:
  - Para ejecutar `terraform`/`deploy` desde Actions, actualizar los tres secretos temporales por sesión; nunca subirlos al repositorio.
  - Variable en cada Environment: `TF_STATE_BUCKET`.
- [ ] Branch protection en `main`: exigir que el CI pase.

### Seguridad y escaneo IaC
- [x] Terraform y los overlays actuales son la única infraestructura; se eliminaron CloudFormation, `k8s/legacy` y los scripts del laboratorio. Trivy escanea todo Terraform.
- [x] Documentada la salida global temporal (`AWS-0104`): necesaria para descargas sin endpoints privados; no hay entrada pública en los nodos.
- [x] Documentadas las excepciones: SSE-S3 por permisos KMS insuficientes y ELB HTTP público requerido por la demo. No se habilita SSE-KMS.
- [x] Imágenes de los cinco microservicios ejecutan como usuario sin privilegios (`DS-0002`); archivos de la app son legibles y temporales del worker/upload van en `/tmp`.
- [x] Añadido `runAsNonRoot`, UID/GID no privilegiado y seccomp RuntimeDefault en los cinco workloads de aplicación. `readOnlyRootFilesystem` queda pendiente hasta validarlo en despliegue.
- [x] Endurecidos los cinco pods: deshabilitada la elevación de privilegios, eliminadas todas las Linux capabilities y deshabilitado el montaje automático del token de ServiceAccount.
- [x] Añadido job CI para ejecutar pruebas unitarias del panel `k8s-web`; no sustituye pruebas unitarias de los microservicios.
- [x] Volver a ejecutar Trivy/Checkov en GitHub: el job `IaC security scan` pasó en `main` (`735b619`). Checkov continúa en `soft_fail`; Trivy mantiene el bloqueo para `HIGH`/`CRITICAL` no exceptuados.

### Terraform
- [ ] Crear en GitHub el Environment `desarrollo`, configurar `TF_STATE_BUCKET` y actualizar `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` en cada sesión.
- [x] Bootstrap/backend remoto: lo crea `aws/init-account.sh` (`vibe-tfstate-<cuenta>`).
- [ ] En Actions, ejecutar `terraform.yml` con `action=plan`, revisar el plan y luego lanzar `action=apply` en una ejecución separada.
- [x] Entrar al servidor mediante SSM y ejecutar `cluster-init.sh` con el rol de los nodos.
- [x] Verificar la app por la URL del ELB: `/`, `/api/stats` y `/api/tracks` respondieron HTTP 200.
- [ ] Probar `deploy.yml` con el SHA de una imagen publicada en GHCR; comprobar permisos SSM y visibilidad del paquete para EC2.
- [ ] Ejecutar `action=destroy` al terminar la práctica si se requiere borrado controlado antes de que venza la sesión.

### Revisión IaC (infrastructure_as_code_cap01-09.md)
- [x] CI publica imágenes también desde `develop`; eliminada la referencia a la rama borrada `integracion_terraform`.
- [x] `make aws-up`/`aws-down` usan Terraform (`deploy-aws.sh`/`destroy-aws.sh`).
- [x] Versión de Terraform unificada (1.16.6) y versión de KEDA en un único archivo (`k8s/KEDA_VERSION`).
- [x] `deploy-ghcr.sh` fija imágenes con el transformador `images:` de kustomize en vez de `sed`.
- [x] `terraform.yml`: `destroy` exige `confirm_destroy` con el nombre del entorno.
- [ ] Configurar *required reviewers* en los GitHub Environments (aprobación antes de apply/destroy).
- [ ] Aplicar los wrappers RDS de staging/producción: nunca se han probado con `apply`.
- [ ] Pasar Checkov de `soft_fail` a bloqueante cuando se revisen sus hallazgos.
- [ ] Unificar `envs/staging` y `envs/produccion` (hoy duplican `main.tf`/`variables.tf`) y versionar los módulos.
- [ ] Revisar `deletion_protection`/`skip_final_snapshot` de RDS antes de un uso real de producción.

### Migración a cuenta AWS propia (us-east-2, 100 USD de créditos)
- [x] Región `us-east-2` en Terraform, scripts y workflows; PostgreSQL 16.15 (la 16.16 no existe en esta región).
- [x] Rol e instance profile de los nodos en Terraform (`modules/node-iam`), con SSM y CloudWatch Agent: sustituye a `LabInstanceProfile` y desbloquea métricas de memoria/logs.
- [x] Stack `terraform/account`: guardián de créditos (Lambda horaria que pausa EC2/RDS `Project=vibe` bajo el umbral) y roles OIDC de GitHub. Con pruebas unitarias en CI; `terraform plan` leído contra la cuenta (15 recursos) sin errores.
- [x] `deploy.yml`: entrada `commit_sha`, imagen `sha-<SHA>`, verificación de GHCR/servidor/SSM, comprobación de salud y rollback automático en `deploy-ghcr.sh`.
- [x] Workflows con OIDC en lugar de credenciales temporales.
- [x] Pipeline CD: `develop` → desarrollo, `main` → staging → producción (aprobación) con el mismo SHA; deriva diaria (`terraform-drift.yml`). Se activa con las variables de repositorio `AUTO_DEPLOY` y `DRIFT_CHECK`.
- [ ] Poner *Required reviewers* en el Environment `produccion` y activar `AUTO_DEPLOY` tras el primer despliegue manual correcto.
- [ ] Ejecutar `aws/init-account.sh` (crea state, guardián y roles OIDC) y crear las variables en los GitHub Environments.
- [ ] Desplegar desarrollo (`aws/deploy-aws.sh`) y verificar el guardián con `guard_dry_run` antes de dejarlo activo.
- [ ] Los Ingress de desarrollo/staging/producción no tienen `host` y comparten el mismo Traefik/ELB con la ruta `/`: añadir reglas por host o ruta antes de desplegar staging/producción.
- [ ] Las apps reciben credenciales temporales del rol copiadas a un Secret (`cluster-init.sh`) que caducan: sustituir por lectura directa del rol o rotación.

### Mejoras siguientes
- [x] Añadido workflow manual `deploy.yml` para el despliegue por SSM. Falta validar permisos y ejecución real en AWS.
- [x] Añadida publicación de imágenes a GHCR con tags por commit en CI. Requiere configurar los paquetes como públicos para que EC2 pueda hacer pull sin credenciales.
- [ ] Secretos de la app (Postgres `vibe/vibe`) fuera de Git: SSM Parameter Store o SOPS.
- [x] Añadido escaneo Trivy/Checkov y TFLint al CI; confirmar que el workflow queda verde.
- [x] Añadido Dependabot para Actions e imágenes de contenedor. KEDA/k3s se mantienen en los manifiestos y requieren revisión manual.
- [ ] Opcional: Argo CD para GitOps de la parte Kubernetes.

### Base de datos y resiliencia
- [x] AWS genera una contraseña PostgreSQL aleatoria en la primera inicialización, la persiste en el Secret `vibe-secrets` de Kubernetes y pasa `DATABASE_URL` desde ese Secret. Los overlays locales conservan credenciales solo para pruebas; aún falta migrar el Secret persistido a SSM/Secrets Manager.
- [x] Limitar pools SQL: catálogo 3+1, upload 2+1, worker 1+0. Con los máximos de desarrollo (8/8/8 réplicas) el máximo teórico es 64 conexiones de aplicación; queda pendiente validar ese máximo contra PostgreSQL bajo carga.
- [x] Prueba AWS de caída/recuperación de Postgres (`vibe/aws/demo.py db`): volvió a 1/1 y la API recuperó HTTP 200 en 12,076 s. Durante la caída `/api/tracks` tuvo 22/29 errores; HLS tuvo 0/29. Evidencia: `C:\Users\Michael\vibe-evidence\20261028T070734Z-db`.
- [ ] Validar aparte el arranque de las APIs mientras Postgres no está disponible (orden de despliegue y reintentos al iniciar).
- [x] Reinicios graduales de catalog-api, upload-api y stream-api en AWS: rollouts completos; endpoints principales volvieron a HTTP 200.
- [x] Fallo de un pod de catalog-api: Kubernetes lo repuso en 8,957 s; 2/3 sondeos excedieron el timeout de 3 s. Evidencia: `C:\Users\Michael\vibe-evidence\20261028T073933Z-pod`.
- [x] Prueba de carga k6 de oyentes: 1 VU/1 min y 10 VUs/2 min sin errores HTTP; p95 de 580,9 ms y 1.460 ms respectivamente, ambos sobre el objetivo de 500 ms. Resúmenes en `results/k6/aws-users-1vu-20261028.json` y `results/k6/aws-users-10vu-20261028.json`.
- [x] Prueba de HPA de catálogo a 4/12/24 solicitudes concurrentes: 2.131 solicitudes, 236 timeouts/fallos del cliente (11,075%), p95 9.024,5 ms; HPA permaneció en 2 réplicas. Evidencia: `C:\Users\Michael\vibe-evidence\20261028T073442Z-hpa`.
- [ ] Investigar latencia/timeouts y por qué el HPA no escaló; repetir desde un generador en `us-east-1` y medir CPU, conexiones y espera de PostgreSQL antes de afirmar capacidad.
- [x] Prueba de flujo worker/KEDA: 12 audios sintéticos procesados, cola pico 9, máximo 5 workers, 302,3 s; tracks de prueba eliminados y cola Redis verificada en cero. Evidencia: `C:\Users\Michael\vibe-evidence\20261028T074031Z-keda`.
- [ ] Ejecutar una prueba controlada de caída de nodo/EC2; requiere credenciales AWS activas y verificar de antemano la ubicación de PVC locales.
- [ ] Ejecutar OOM del worker solo con ventana de prueba y restauración de 512 MiB verificada; no se completó esta sesión.
- [x] Revisada la disponibilidad de RDS PostgreSQL en `us-east-2`: `db.t3.micro` admite Multi-AZ y PostgreSQL 16.9–16.15. Añadido el módulo Terraform reutilizable y wrappers `staging` Single-AZ y `produccion` Multi-AZ; todavía no se han aplicado.
- [ ] Revisar el costo con el presupuesto actual, confirmar permisos con un plan/apply controlado y desplegar staging/produccion por turnos; ejecutar y documentar prueba de failover.
- [x] Crear overlays Kubernetes separados para desarrollo, staging y producción. Staging/producción omiten PostgreSQL local y usan namespaces independientes; CI renderiza los cuatro overlays (`test`, `desarrollo`, `staging`, `produccion`) y valida también los tres wrappers Terraform.
- [ ] Crear usuario PostgreSQL de aplicación con permisos restringidos y distribuir `DATABASE_URL`/credenciales S3 a los Secrets aislados de staging y producción mediante un mecanismo seguro.
- [ ] Desplegar staging y producción con `deploy.yml`; validar conectividad a sus RDS y guardar evidencia. El workflow reutiliza el clúster K3s de desarrollo.
- [ ] Definir backups automatizados y probar restauración; PVC local no ofrece recuperación entre nodos.
- [ ] Hacer durable y reintentable la cola de transcodificación (ACK tras completar, reintentos e idempotencia).
- [x] Preparado Terraform para dashboard CloudWatch y alarmas de estado/CPU EC2, salud/latencia/HTTP 5xx del Classic ELB; SNS por correo opcional (`VIBE_ALERT_EMAIL`).
- [ ] Aplicar el módulo de monitoreo en AWS, comprobar datos del dashboard bajo tráfico y confirmar la suscripción SNS si se configuró correo.
- [ ] Integrar CloudWatch Agent para memoria, logs de sistema y logs de contenedores; el rol de los nodos ya incluye `CloudWatchAgentServerPolicy`; falta instalar el agente.
- [x] ServiceMonitor local actualizado para catalog-api, upload-api, stream-api y worker; validar instalación AWS con Prometheus real.
