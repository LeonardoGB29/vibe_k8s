# k8s web · visor local de la arquitectura del cluster

Página independiente (no forma parte de la app ni se despliega en ningún contenedor)
para ver cómo Kubernetes gestiona el proyecto: arquitectura, nodos, pods, escalado,
red, almacenamiento y eventos. Consulta `kubectl` cada 2 segundos.

```bash
python3 server.py                     # http://localhost:8085  (namespace vibe)
python3 server.py --ns otro --port 9000
python3 server.py --status-script ""  # sin la pestaña Terminal
```

Requisitos: Python 3.9+ (solo librería estándar) y `kubectl` apuntando al cluster.
En Windows: `python server.py`; la pestaña Terminal necesita `bash` (Git Bash).

| Pestaña | Qué muestra |
|---|---|
| Arquitectura | Diagrama generado en vivo: Ingress → Services → Deployments/StatefulSets → Pods → PVCs, con HPA y KEDA sobre lo que escalan |
| Nodos | Estado, versión, CPU y RAM (uso / asignable) y pods que corren en cada uno |
| Pods | Label, dueño, nodo, estado, reinicios, CPU y RAM (uso / request / limit), imagen, IP, edad |
| Escalado | Gráficos en vivo de réplicas (HPA con CPU %, KEDA), tabla de autoescaladores y workloads |
| Red y almacenamiento | Ingress, Services, PVCs, ConfigMaps y Secrets |
| Eventos | Últimos 15 eventos del namespace (warnings en rojo) |
| Pruebas | Centro visual para iniciar, seguir y detener cargas, escalabilidad y simulaciones de resiliencia |
| Terminal | Salida de `vibe/tools/cluster-status.sh` refrescada cada ~6 s |

## Centro de pruebas

La pestaña **Pruebas** ofrece escenarios predefinidos; no acepta comandos arbitrarios.
Solo permite una ejecución principal a la vez y muestra estado, fase, duración, salida en
tiempo real y evidencias generadas. Las simulaciones de fallo requieren confirmación.

- Rendimiento: carga sostenida, estrés, pico y usuarios fijos.
- Escalabilidad: carga de uploads y observación de KEDA.
- Resiliencia: fallo de pod, caída de nodo, reinicio de PostgreSQL, rolling update y OOM.
- Recuperación: restauración del límite de memoria del worker.

En la caída de nodo, la prueba comprueba que cada servicio afectado obtiene un pod
nuevo asignado a otro nodo e informa su fase y si está `Ready` o `NotReady`.
Un reemplazo puede quedar `NotReady` si depende de PostgreSQL, MinIO o Redis alojado
en el nodo apagado; la disponibilidad total se valida después de restaurar el nodo.
El pod antiguo puede permanecer temporalmente en `Terminating` mientras el kubelet
está desconectado; esto no se considera un fallo. Antes de comenzar, el panel también
advierte si el nodo aloja un StatefulSet o un PVC, porque ese servicio con estado no
puede reprogramarse con el almacenamiento local del cluster kind.

Al detener una prueba, el servidor cancela su árbol de procesos y ejecuta la restauración
correspondiente para nodo, rolling update u OOM. El servidor escucha únicamente en
`127.0.0.1`; debe mantenerse así porque las acciones modifican el cluster local.

# Requisitos y ejecución rápida

Solo para visualizar: Python 3.9 o superior y `kubectl` configurado. El servidor usa la biblioteca estándar de Python; `metrics-server` habilita las métricas de uso. Si falta una métrica, el dashboard debe indicar N/A.

Para ejecutar todas las pruebas: Python 3.10 o superior, Docker Desktop/Docker, Kind, `kubectl`, GNU Make, k6, Bash (Git Bash en Windows) y `curl` para los sondeos de resiliencia. Las pruebas de carga de archivos requieren audios en `vibe/data/audio`; se pueden generar con `make gen-audio`. Para escenarios que reinician nodos se necesita acceso a los contenedores Kind desde Docker.

Desde `k8s-web`:

```bash
python server.py
python server.py --ns vibe --port 8085
python server.py --ns staging --vibe-dir ../vibe --status-script=
```

`--vibe-dir` permite indicar otra ubicación del proyecto y por defecto se mantiene la carpeta hermana `../vibe`. `--ns` se aplica a las consultas Kubernetes y a los objetivos Make invocados por el panel. El script de terminal integrado fija `vibe`, por lo que se omite en otros namespaces.

Desde `vibe/`: `make k6-load`, `make k6-stress`, `make k6-spike`, `make k6-users VUS=500 DURATION=3m` y `make k6-ramp`. `k6-users` sigue usando concurrencia fija; `k6-ramp` añade subida gradual hasta 1200 VUs. Las pruebas conservan salida k6 normal y guardan JSON en `vibe/results/k6/`.
