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
- [x] Confirmado sandbox AWS Academy disponible: región `us-east-1`, `LabInstanceProfile`/`LabRole` y `vockey` precreados, máximo de 9 EC2.
- [x] Confirmar capacidad del sandbox para desplegar cuatro EC2 con discos de 20 GB y 15 GB: el despliegue real terminó correctamente.
- [x] Revisión de cuotas y costo el 28/10/2026: cuatro EC2 activas (8 vCPU) de un límite AWS Academy de 9 instancias; cuota estándar EC2 reportada por Service Quotas: 256 vCPU. Cost Explorer mostró USD 0,319 acumulados del 1 al 29 de octubre para la cuenta (sin filtrar por proyecto/etiquetas; cifra orientativa para el sandbox).
- [x] `terraform plan` sin cambios después del `apply`; comprobado en CloudShell el 28/10/2026.
- [x] Crear y usar `k8s-web/connect-aws-tunnel.ps1` desde Windows; túnel SSM confirmado. `kubectl get nodes` mostró los cuatro nodos `Ready` y todos los pods de `vibe` estaban `Running`/`Ready` el 28/10/2026.

Estado de ejecución: el PR #1 ya está integrado en `main`. VIBE se desplegó desde
`aws/deploy-sandbox.sh`; los pods quedaron listos y `/`, `/api/stats` y
`/api/tracks` respondieron HTTP 200 en el ELB `http://vibe-desarrollo-elb-643350216.us-east-1.elb.amazonaws.com`. El fin o vencimiento de una sesión
normal detiene las EC2, pero conserva los recursos y el state remoto; **Reset** sí
borra el entorno y obliga a preparar uno nuevo. Al reanudar, renueva las
credenciales temporales y comprueba que los servicios vuelvan a responder.

## Por hacer

### GitHub
- [x] Integrar el PR #1 `integracion_terraform` → `main`.
- [ ] Revisar los PRs de Dependabot abiertos (#2, #3, #4 y #6); sus checks de IaC fallan en las ejecuciones actuales. El PR #5 está cerrado sin merge. Los PRs apuntan a la base `a941331`, anterior al `main` actual (`735b619`); actualizar/revalidar antes de integrar.
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
- [x] Volver a ejecutar Trivy/Checkov en GitHub: el job `IaC security scan` pasó en `main` (`735b619`). Checkov continúa en `soft_fail`; Trivy mantiene el bloqueo para `HIGH`/`CRITICAL` no exceptuados.

### Terraform
- [ ] Crear en GitHub el Environment `desarrollo`, configurar `TF_STATE_BUCKET` y actualizar `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` en cada sesión.
- [x] Bootstrap/backend remoto disponible; `terraform plan` accedió al state en `vibe-tfstate-911045829576`. Repetir bootstrap solo tras usar **Reset** o recibir una cuenta de laboratorio nueva.
- [ ] En Actions, ejecutar `terraform.yml` con `action=plan`, revisar el plan y luego lanzar `action=apply` en una ejecución separada.
- [x] Entrar al servidor mediante SSM y ejecutar `cluster-init.sh` usando `LabInstanceProfile`.
- [x] Verificar la app por la URL del ELB: `/`, `/api/stats` y `/api/tracks` respondieron HTTP 200.
- [x] Revisado CloudFormation el 28/10/2026: no hay stack antiguo de VIBE; los tres stacks listados pertenecen al Lab IDE de AWS Academy y se conservan.
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
- [ ] Evaluar RDS PostgreSQL Single-AZ (el sandbox no permite Multi-AZ; clases nano–medium) frente al PostgreSQL del clúster, incluyendo costo y permisos.
- [ ] Definir backups automatizados y probar restauración; PVC local no ofrece recuperación entre nodos.
- [ ] Hacer durable y reintentable la cola de transcodificación (ACK tras completar, reintentos e idempotencia).
- [ ] Instalar métricas/alertas persistentes en AWS.
- [x] ServiceMonitor local actualizado para catalog-api, upload-api, stream-api y worker; validar instalación AWS con Prometheus real.
