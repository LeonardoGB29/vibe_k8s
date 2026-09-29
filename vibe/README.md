# VIBE · Plataforma de streaming de audio sobre Kubernetes

## Despliegue actual en AWS Academy

La aplicación actual tiene cinco microservicios: frontend, catalog-api, upload-api,
stream-api y worker. En AWS se ejecutan en cuatro EC2 con k3s, Traefik y S3 real.
HPA escala las APIs por CPU; KEDA escala workers por la cola Redis (máximo 8 en AWS).

Consulta [la guía AWS actualizada](aws/README.md) y
[los ensayos medidos](aws/DEMONSTRATIONS.md).
Los apartados históricos de arranque local de este documento aún contienen
referencias al monolito api; para la demostración AWS utiliza esas dos guías.

Proyecto académico: una app de música (subida, transcodificación a HLS y reproducción)
desplegada en Kubernetes para evaluar **escalabilidad**, **tolerancia a fallos** y
**pruebas de estrés**, y mostrar cómo Kubernetes gestiona decenas de contenedores.

```
 Navegador ──► Ingress (nginx) ──► api (FastAPI, N réplicas, HPA por CPU)
                                     │  /            frontend (HTML/JS + hls.js)
                                     │  /api/tracks  catálogo + subida
                                     │  /stream/...  segmentos HLS (proxy desde MinIO)
                                     ├──► PostgreSQL (StatefulSet + PVC)   metadatos
                                     ├──► MinIO      (StatefulSet + PVC)   raw/ y hls/
                                     └──► Redis      cola "transcode"
                                              │
                          worker (ffmpeg → HLS 64k/128k + waveform) × 1..30 pods (KEDA)
```

| Componente | Tecnología | Objeto K8s |
|---|---|---|
| api | Python 3.12, FastAPI, SQLAlchemy, MinIO SDK | Deployment (2..10) + HPA + PDB |
| worker | Python 3.12 + ffmpeg | Deployment (1..30) + KEDA ScaledObject |
| frontend | HTML/CSS/JS servido por la api, hls.js | (dentro de api) |
| postgres | postgres:16 | StatefulSet + PVC |
| minio (SeaweedFS) | S3 self-hosted, API compatible | StatefulSet + PVC |
| redis | redis:7 | Deployment + PVC |
| monitoreo | kube-prometheus-stack (Prometheus + Grafana) | Helm |

## Requisitos (Mac y Windows)

```bash
python3 tools/setup.py             # muestra qué tienes y qué falta, no instala nada
python3 tools/setup.py --install   # instala solo lo que falta (brew en Mac, winget en Windows)
```

Docker Desktop (u OrbStack en Mac) con 8 a 10 GB de RAM asignados. En Windows: Docker Desktop con WSL2
y los comandos `make` y `chaos/*.sh` se ejecutan desde **Git Bash** (viene con Git for Windows).
Dependencias Python de todo el proyecto en `requirements.txt` (solo necesarias fuera de Docker).

## Arranque rápido

```bash
# 1. Probar sin Kubernetes (API en http://localhost:8000)
make compose

# 2. Todo en Kubernetes (cluster kind + addons + imágenes + despliegue). ~10 min la primera vez
make up

# 3. Dataset sintético (sin derechos de autor) y carga inicial
make gen-audio          # 200 mp3 en data/audio
make seed               # los sube a http://localhost (API=http://localhost:8000 para compose)

# 4. Ver
open http://localhost   # la app
make grafana            # http://localhost:3000  admin / vibe
k9s -n vibe             # pods en vivo
```

## Pruebas

| Prueba | Comando | Qué observar |
|---|---|---|
| Carga | `make k6-load` | p95, tasa de error, réplicas de `api` en Grafana |
| Estrés | `make k6-stress` | punto de quiebre (1500 VUs) |
| Pico | `make k6-spike` | cuánto tarda el HPA en reaccionar |
| N usuarios | `make k6-users VUS=500 DURATION=3m` | p95 y error para una concurrencia fija |
| Escalabilidad del worker | `make worker-scale UPLOADS=200` | cola Redis y KEDA de 1 a 30 pods |
| Fallo de pod | `make chaos-pod INTERVAL=15 TIMES=6` | tiempo de recuperación y errores HTTP |
| Fallo de nodo | `make chaos-node NODE=vibe-worker DOWN=180` | pods stateless reprogramados en otros nodos |
| Fallo de BD | `make chaos-db` | mismo PVC y datos intactos |
| Rolling update | `make chaos-rolling VERSION=v2` | cero errores durante despliegue y restauración |
| Límite de memoria | `make chaos-oom` / `make chaos-oom-restore` | OOMKilled verificado y restauración |

Cada prueba se corre 3 veces y se reporta el promedio. Capturas en `docs/evidencia/`.

Paneles útiles en Grafana: *Kubernetes / Compute Resources / Namespace (Pods)* con namespace `vibe`,
Visor de arquitectura independiente (fuera del cluster): `python3 ../k8s-web/server.py`.

y consultas Prometheus:

```promql
kube_deployment_status_replicas_available{namespace="vibe"}
sum(rate(http_requests_total{namespace="vibe"}[1m])) by (handler)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="vibe"}[1m])) by (le))
redis list: keda_scaler_metrics_value{scaledObject="worker"}
```

## Notas

- **Nodo caído:** los deployments stateless usan `tolerationSeconds: 15`; los servicios con PVC conservan
  el valor predeterminado. Así la prueba de 180 s reprograma las API sin evacuar almacenamiento local.
- **Almacenamiento S3:** MinIO retiró sus imágenes de Docker Hub en 2026, por eso se usa SeaweedFS (`chrislusf/seaweedfs`) con la misma API S3. El Service y las variables siguen llamándose `minio` para no tocar la API ni el worker.
- **Imágenes en kind:** tras cambiar código, `make redeploy` (build + load + restart).
- **Audios:** todo el dataset es sintético (generado con ffmpeg). Si suben música propia, usen pistas con licencia CC0 (Pixabay, Free Music Archive).

## Estructura

```
api/         FastAPI + frontend estático (app/static)
worker/      transcodificador ffmpeg
tools/       gen_audio.py (dataset), seed.py (carga masiva)
k8s/         manifiestos (00..70) y kind-config.yaml
tests/k6/    load, stress, spike, upload
chaos/       scripts de tolerancia a fallos
docs/        informe y evidencia
```
