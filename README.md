# VIBE · Plataforma de streaming de audio sobre Kubernetes

## Despliegue actual en AWS Academy

La aplicación actual tiene cinco microservicios: frontend, catalog-api, upload-api,
stream-api y worker. En AWS se ejecutan en cuatro EC2 con k3s, Traefik y S3 real.
HPA escala las APIs por CPU; KEDA escala workers por la cola Redis (máximo 8 en AWS).

Consulta [la guía AWS actualizada](vibe/aws/README.md) y
[los ensayos medidos](vibe/aws/DEMONSTRATIONS.md).
Los apartados históricos de arranque local de este documento aún contienen
referencias al monolito api; para la demostración AWS utiliza esas dos guías.

Proyecto académico de Kubernetes: una app de música (subida, transcodificación a HLS y
reproducción) desplegada en un cluster local para evaluar **escalabilidad**, **tolerancia a
fallos** y **pruebas de estrés**, y observar cómo Kubernetes gestiona decenas de contenedores.

```
k8s/
├── vibe/       la aplicación: código, Dockerfiles, manifiestos, pruebas y scripts de fallos
└── k8s-web/    visor local de la arquitectura del cluster (no se despliega, solo lee kubectl)
```

## Arquitectura

```
Navegador ──► Ingress (nginx) ──► api (FastAPI, 2..10 réplicas, HPA por CPU)
                                   │  /             frontend (HTML/JS + hls.js)
                                   │  /api/tracks   catálogo y subida
                                   │  /stream/...   segmentos HLS (proxy desde S3)
                                   ├──► PostgreSQL  (StatefulSet + PVC)  metadatos
                                   ├──► SeaweedFS   (StatefulSet + PVC)  S3: originales y HLS
                                   └──► Redis       cola "transcode"
                                            │
                        worker (ffmpeg → HLS 64k/128k + waveform) 1..30 pods (KEDA)
```

| Componente | Tecnología | Objeto Kubernetes |
|---|---|---|
| api | Python 3.12, FastAPI, SQLAlchemy, cliente S3 | Deployment + HPA + PDB |
| worker | Python 3.12 + ffmpeg | Deployment + KEDA ScaledObject |
| frontend | HTML/CSS/JS servido por la api, hls.js | (dentro de api) |
| postgres | postgres:16 | StatefulSet + PVC |
| minio (SeaweedFS) | almacenamiento S3 compatible | StatefulSet + PVC |
| redis | redis:7 | Deployment + PVC |
| monitoreo | kube-prometheus-stack (Prometheus + Grafana) | Helm |

## Requisitos

Mac o Windows. Docker Desktop (u OrbStack en Mac) con **8 GB de RAM** asignados.
En Windows: Docker Desktop con WSL2 y **Git Bash** para `make` y los scripts `.sh`.

```bash
cd vibe
python3 tools/setup.py             # muestra qué herramientas tienes y cuáles faltan
python3 tools/setup.py --install   # instala solo lo que falta (brew en Mac, winget en Windows)
```

Herramientas: docker, kind, kubectl, helm, k6, ffmpeg, make, k9s (opcional), Python 3.9+.

## 1. Levantar la aplicación

### Opción rápida sin Kubernetes (docker-compose)

```bash
cd vibe
make compose                                  # API en http://localhost:8000
make gen-audio                                # genera 200 audios sintéticos en data/audio
API=http://localhost:8000 make seed           # los sube
make compose-down                             # apagar
```

### En Kubernetes (kind, 1 control-plane + 3 workers)

```bash
cd vibe
make up            # crea el cluster, instala ingress-nginx, metrics-server, KEDA y Prometheus/Grafana,
                   # construye las imágenes y despliega todo (~10 min la primera vez)
make status        # todos los pods en Running
make gen-audio     # 200 mp3 sintéticos (sin derechos de autor)
make seed          # los sube al cluster; el worker escala de 1 a N pods
```

Abrir **http://localhost** (la app) y, en otra terminal, `make grafana` para
**http://localhost:3000** (usuario `admin`, clave `vibe`).

| Comando | Qué hace |
|---|---|
| `make redeploy` | reconstruye imágenes tras cambiar código y reinicia los pods |
| `make logs-api` / `make logs-worker` | logs en vivo |
| `make watch` | pods por nodo en vivo |
| `tools/cluster-status.sh -w` | radiografía completa del cluster en terminal |
| `make down` | destruye el cluster |

Si `make up` se corta, vuelve a ejecutarlo: todos los pasos son idempotentes.

## 2. Levantar el visor del cluster (k8s-web)

Página local, blanco y azul, que muestra cómo Kubernetes gestiona la app. No se despliega en
ningún contenedor: es un servidor Python (solo librería estándar) que ejecuta `kubectl` cada 2 s.

```bash
cd k8s-web
python3 server.py                  # http://localhost:8085
python3 server.py --port 9000      # otro puerto
python3 server.py --ns monitoring  # otro namespace
```

| Pestaña | Qué muestra |
|---|---|
| Arquitectura | Diagrama generado en vivo: Ingress → Services → Deployments/StatefulSets → Pods → PVCs, con HPA y KEDA |
| Nodos | CPU y RAM uso vs asignable, versión, pods de cada nodo |
| Pods | label, dueño, nodo, estado, reinicios, CPU/RAM uso / request / limit, imagen, IP |
| Tráfico | peticiones por segundo que atiende cada réplica de api, segmentos HLS/s, Mbit/s, reparto entre pods |
| Escalado | gráficos en vivo de réplicas (HPA con CPU %, KEDA), autoescaladores y workloads |
| Red y almacenamiento | Ingress, Services, PVCs, ConfigMaps y Secrets |
| Eventos | últimos 15 eventos del namespace |
| Terminal | salida de `vibe/tools/cluster-status.sh` |

## 3. Pruebas

Con la app en Kubernetes y el visor abierto en las pestañas **Tráfico** y **Escalado**:
e34

Cada usuario virtual de k6 se comporta como un oyente: lista el catálogo, pide la playlist HLS y
descarga segmentos de audio. Al terminar, k6 imprime `http_req_duration p(95)`, `http_req_failed`
y si se cumplieron los umbrales. Cada prueba se corre 3 veces y se reporta el promedio.
Evidencia en `vibe/docs/evidencia/`.

## Notas

- **Datos:** las canciones no viven en el repo sino en los volúmenes del cluster. Al clonar en otra
  máquina, `make gen-audio && make seed` regenera el mismo dataset (semilla fija).
- **Almacenamiento S3:** MinIO retiró sus imágenes de Docker Hub en 2026, por eso se usa SeaweedFS
  con la misma API. El Service y las variables se siguen llamando `minio`.
- **Nodo caído:** Kubernetes espera 5 min antes de mover pods de un nodo NotReady
  (`tolerationSeconds`). Para la demo se puede bajar a 15 s, ver `vibe/README.md`.
- **Audios:** todo el dataset es sintético, generado con ffmpeg. No hay música con derechos.
