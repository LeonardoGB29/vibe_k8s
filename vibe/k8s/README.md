# Entornos Kubernetes de VIBE

Los overlays comparten los microservicios de `base`, pero aíslan la
configuración por namespace:

| Entorno | Overlay | Namespace | Base de datos |
|---|---|---|---|
| Pruebas | `overlays/test` | `vibe` | PostgreSQL local para kind/CI |
| Desarrollo | `overlays/desarrollo` | `vibe` | PostgreSQL local en el clúster AWS actual |
| Staging | `overlays/staging` | `vibe-staging` | RDS PostgreSQL Single-AZ |
| Producción | `overlays/produccion` | `vibe-produccion` | RDS PostgreSQL Multi-AZ |

Staging y producción no incluyen el StatefulSet de PostgreSQL. Los servicios
leen `DATABASE_URL` del Secret `vibe-secrets` en su propio namespace. Ese Secret
debe contener una URL del endpoint RDS con un usuario de aplicación restringido,
además de las claves S3 temporales requeridas por los servicios. No se guarda en
Git ni se copia desde desarrollo. El proceso automatizado de creación del rol
PostgreSQL y distribución segura de este Secret sigue pendiente.

Los otros ajustes (Redis, región y buckets S3) se copian desde el ConfigMap
`vibe-config` de desarrollo si no existen en el namespace de destino. Esto
permite compartir los buckets del entorno AWS existente mientras se prueban las
bases separadas.

## Renderizar o desplegar

```bash
kubectl kustomize overlays/test
kubectl kustomize overlays/desarrollo
kubectl kustomize overlays/staging
kubectl kustomize overlays/produccion

kubectl apply -k overlays/staging
kubectl apply -k overlays/produccion
```

Para GitHub Actions, `deploy.yml` recibe el SHA de la imagen y el entorno de
destino (`desarrollo`, `staging` o `produccion`). Usa el clúster K3s del entorno
desarrollo como cómputo compartido y aplica el overlay al namespace elegido. El
Environment de GitHub correspondiente debe tener credenciales temporales AWS
vigentes. Staging/producción deben tener su Secret de aplicación antes de
ejecutar el workflow.

En CI se renderizan y validan los cuatro overlays, y Terraform valida los
wrappers de desarrollo, staging y producción. `test` continúa usando kind.
