# Pendientes · integración Terraform + CI

## Para revisar

- [ ] CI verde en el PR (`manifests`, `dockerfiles`, `build`, `terraform`, `test-kind`).
- [ ] `test-kind`: si los pods quedan `Pending` por falta de CPU/RAM en el runner, crear un overlay `ci` con 1 réplica.
- [ ] `kubectl kustomize k8s/overlays/test` y `.../desarrollo` renderizan bien (ScaledObject del overlay `desarrollo` con `maxReplicaCount: 8`).
- [ ] Cambio de orden en el despliegue: las APIs ya no esperan a Postgres/MinIO antes de crearse. Comprobar que no hay reinicios problemáticos.
- [ ] Versión de k3s (`v1.31.4+k3s1`): confirmar que existe, o cambiarla con `-var k3s_version=...`.
- [ ] Permisos de `LabInstanceProfile` sobre SSM (`ssm:GetParameter`): los nodos lo usan para leer el token.
- [ ] Cuota del Academy: 8 EC2 a la vez (stack viejo + nuevo). Si no alcanza, borrar el viejo antes (`make aws-down`).
- [ ] `terraform plan` sin cambios tras el primer `apply` (idempotencia).

## Por hacer

### GitHub
- [ ] Abrir el PR `integracion_terraform` → `main`.
- [ ] Pedir permisos de admin en el repo (o usar un fork) para crear Environments y Secrets.
- [ ] Crear el Environment `desarrollo`:
  - Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (caducan con el lab).
  - Variable: `TF_STATE_BUCKET`.
- [ ] Branch protection en `main`: exigir que el CI pase.

### Terraform
- [ ] Ejecutar `terraform/bootstrap` una vez y anotar `state_bucket`.
- [ ] `terraform init -backend-config=backend.hcl` y `apply` en `envs/desarrollo`.
- [ ] Entrar al servidor con `aws ssm start-session` y ejecutar `cluster-init.sh` (comando en `terraform output cluster_init_command`).
- [ ] Verificar la app por la URL del ELB y borrar el stack viejo de CloudFormation.

### Mejoras siguientes
- [ ] Workflow `deploy.yml` para desplegar la app en `desarrollo` (SSM `send-command`).
- [ ] Registry de imágenes (ECR/GHCR) con tag por commit en vez de `:dev` y build en el servidor.
- [ ] Secretos de la app (Postgres `vibe/vibe`) fuera de Git: SSM Parameter Store o SOPS.
- [ ] Escaneo de seguridad en el CI: `trivy config` / `checkov` y `tflint`.
- [ ] Renovate o Dependabot para versiones (KEDA, k3s, imágenes, actions).
- [ ] Opcional: Argo CD para GitOps de la parte Kubernetes.
