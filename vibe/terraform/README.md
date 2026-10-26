# Terraform · VIBE

```
bootstrap/            bucket S3 del state (una sola vez, state local)
modules/network/      VPC predeterminada, subredes, security groups (sin SSH ni 6443 publicos)
modules/storage/      buckets S3 raw y hls (cifrados, sin acceso publico, solo TLS)
modules/k3s-cluster/  servidor k3s + agentes (for_each), token en SSM, Traefik, ELB
envs/desarrollo/      composicion del entorno desarrollo en AWS
```

`test` no usa Terraform: es un cluster kind (`make up`, o el job `test-kind` del CI).

## Primer uso

```bash
# 1. Bucket del state (una vez por cuenta)
cd terraform/bootstrap
terraform init && terraform apply          # anota el output state_bucket

# 2. Entorno desarrollo
cd ../envs/desarrollo
cp backend.hcl.example backend.hcl         # pon el bucket
terraform init -backend-config=backend.hcl -lockfile=readonly
terraform plan
terraform apply

# 3. Acceso (sin SSH): Session Manager
terraform output ssm_session_command
# dentro del servidor: clonar/subir el repo y ejecutar `terraform output cluster_init_command`
```

## Decisiones

- **State:** S3 con versionado, cifrado, bloqueo (`use_lockfile`) y solo TLS. Un state por entorno (`desarrollo/terraform.tfstate`).
- **Minimo privilegio:** unico puerto publico el 80 del ELB; los nodos solo reciben el NodePort desde el ELB y trafico interno; sin SSH (SSM). El token de k3s sale de `random_id` y se guarda en SSM SecureString, no en el user-data ni en Git. IMDSv2 obligatorio, discos cifrados.
  En AWS Academy no se pueden crear roles IAM, asi que se reutiliza `LabInstanceProfile`.
- **Reproducibilidad:** versiones fijas de k3s, de providers (`~>`) y de Terraform (`>= 1.10`), `.terraform.lock.hcl` versionado, AMI ignorada tras la creacion (`ignore_changes`) para que un plan posterior no recree nodos.
- **Idempotencia:** `terraform plan` sin cambios debe salir vacio. KEDA y la aplicacion no estan en Terraform: las aplica `aws/cluster-init.sh` (`kubectl apply -k k8s/overlays/desarrollo`).

## Secretos de GitHub (Environment `desarrollo`)

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | credenciales del Learner Lab (caducan) |
| Variable | `TF_STATE_BUCKET` | output `state_bucket` del bootstrap |
