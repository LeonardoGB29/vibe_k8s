# Ensayos de VIBE en AWS

El clúster real tiene un servidor k3s y tres agentes EC2, Traefik, S3 y KEDA 2.21.
Los ensayos usan solicitudes HTTP nuevas a través del balanceador y guardan
estados de Kubernetes, series y CSV en ~/vibe-evidence. La latencia se mide desde
la EC2 que genera las solicitudes, no desde el navegador del usuario.

```bash
export KUBECONFIG=~/.kube/config
python3 aws/demo.py pod --base "$BASE_URL"
python3 aws/demo.py hpa --base "$BASE_URL"
python3 aws/demo.py keda --base "$BASE_URL"
python3 aws/demo.py rolling --base "$BASE_URL"
python3 aws/demo.py db --base "$BASE_URL"
python3 aws/demo.py node --base "$BASE_URL"
```

Ejecutar uno por vez. Requieren kubectl, Python 3, curl y AWS CLI. Rolling también
requiere Docker, imágenes :dev y permisos de distribución mediante S3/SSM.

- Pod: elimina exactamente un pod Ready de catálogo, exige al menos otro Ready,
  espera un UID nuevo Ready y la eliminación del anterior; registra errores y p95.
- HPA: 4, 12 y 24 clientes concurrentes, aproximadamente un minuto por etapa.
  Registra CPU y réplicas del catálogo, peticiones, errores y p95.
- KEDA: sube 12 WAV sintéticos de ocho minutos, observa Redis y workers. Solo
  elimina sus propios audios cuando terminaron de convertirse. No pausa KEDA ni
  modifica artificialmente el tamaño de la cola.
- Rolling: construye una imagen distinta de frontend con un archivo marcador,
  la distribuye a todos los agentes y verifica la versión por HTTP. Finalmente
  restaura la imagen original. No simula una actualización reasignando :dev.
- DB: exige un audio listo, detiene PostgreSQL temporalmente y solicita un segmento
  HLS por HTTP repetidamente. El catálogo puede fallar: se registra ese efecto.
  Restaura PostgreSQL aunque el ensayo falle.
- Nodo: solo detiene k3s-agent-3, identificado por IP y etiqueta EC2. Se cancela si
  aloja un PVC o es nodo de control. Mantiene la caída siete minutos para observar
  la detección y posible evicción; restaura la EC2 y espera Ready. No promete que
  la recuperación sea inmediata ni que todas las peticiones tengan éxito.

Limitaciones: un solo servidor de control, PVC locales y Redis BLPOP sin
confirmación/reentrega de trabajos interrumpidos. Eliminar un pod directamente
no prueba protección mediante PDB. No detener nodos de almacenamiento ni el
servidor de control con este procedimiento. Guardar evidencias fuera del Sandbox.
