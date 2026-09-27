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
| Terminal | Salida de `vibe/tools/cluster-status.sh` refrescada cada ~6 s |
