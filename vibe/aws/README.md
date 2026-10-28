# VIBE en AWS Academy Cloud Foundations Sandbox

El despliegue se hará en el sandbox de AWS Academy Cloud Foundations. El sandbox
limita los recursos a `us-east-1`, limpia la cuenta al terminar cada sesión,
permite hasta 9 EC2 concurrentes y provee `LabInstanceProfile`, `LabRole` y la
clave `vockey`. IAM es de solo lectura: se reutilizan esos roles existentes.
El clúster previsto usa cuatro EC2 (`t3.medium` + 3 `t3.small`). Usa volúmenes
EBS gp2 de hasta 35 GB; Terraform configura 20 GB para el servidor y 15 GB para
cada agente.

Ejecuta el despliegue desde una terminal AWS Academy con credenciales CLI
temporales. No hace falta copiarlas a GitHub Secrets. Guarda outputs y evidencias
fuera de AWS antes de que termine la sesión.

## 1. Desplegar con Terraform desde Lab IDE

Usa un checkout actualizado con los cambios de esta guía. El script instala la
infraestructura y la aplicación en una sola ejecución; solicita escribir
`desplegar` antes de crear recursos.

```bash
bash aws/deploy-sandbox.sh
```

El script crea/configura tres buckets con AWS CLI y usa Terraform para crear
cuatro EC2, un ELB y los demás recursos. Este flujo evita la lectura de S3 Object
Lock denegada al proveedor Terraform por la política del rol `voclabs`. Antes de
continuar revisa el espacio disponible en CloudShell, el servidor y cada agente;
limpia la caché Docker antigua y se detiene con un mensaje claro si falta espacio.
Al terminar muestra el estado de pods, servicios e ingress, comprueba `/`,
`/api/stats` y `/api/tracks`, y deja la URL pública al final. El state S3 y el
resto de los recursos desaparecen cuando el sandbox termina la sesión.

La sección CloudFormation que sigue describe el despliegue heredado, no el flujo
recomendado para esta rama.

El CI y el escaneo IaC consideran activos Terraform y los overlays actuales de
`k8s/`; `cloudformation.yaml` y `k8s/legacy/` se conservan como referencia
histórica, pero no se despliegan ni forman parte del gate activo. El stack
CloudFormation antiguo permite SSH, NodePort y API de Kubernetes desde Internet,
no exige IMDSv2 ni cifra explícitamente EBS; no debe usarse en una cuenta real.
El Terraform vigente exige IMDSv2 y cifra los discos. El ELB HTTP público es
intencional para la demo, SSE-S3 se mantiene porque el sandbox no da permisos
KMS suficientes, y el egress global temporal se necesita para paquetes,
imágenes y componentes del clúster sin endpoints privados disponibles.
El script configura los buckets con bloqueo de acceso público, SSE-S3 y una
política TLS; Trivy no inspecciona estas llamadas AWS CLI. Las excepciones IaC
temporales restantes son `AWS-0053` en el ELB y `AWS-0104` en el egress, ambas
con vencimiento el 27 de abril de 2027. El gate sigue fallando ante otros
hallazgos `HIGH` o `CRITICAL`; al vencer, las excepciones vuelven a requerir
revisión.

## 2. Copiar el paquete al servidor

### Desde S3 y Session Manager (ruta recomendada con el clúster creado)

Subir la versión actual de `vibe-aws.tar.gz` desde la consola S3 al bucket Raw,
con la clave `deployment/vibe-aws.tar.gz`. No subir archivos PEM.
Dentro de Session Manager del servidor:

```bash
sudo -iu ec2-user
aws s3 cp s3://RAW_BUCKET_NAME/deployment/vibe-aws.tar.gz ~/vibe-aws.tar.gz --region us-east-1
tar -xzf ~/vibe-aws.tar.gz -C ~
cd ~/vibe_k8s/vibe
bash aws/cluster-init.sh RAW_BUCKET_NAME HLS_BUCKET_NAME
```

El instalador AWS usa Traefik (chart 41.6.0, NodePort 30080) y KEDA 2.21.0,
cuya matriz incluye Kubernetes 1.36. Distribuye las imágenes mediante S3 y SSM
Run Command. Comprueba primero que los tres agentes están Online en SSM.
LabRole necesita permitir lectura EC2, S3 y SSM Run Command; si el Sandbox deniega
alguna acción, se detiene. La alternativa SSH se activa con
`IMAGE_DISTRIBUTION=ssh SSH_PRIVATE_KEY=~/labsuser.pem`.
Las imágenes temporales quedan bajo `deployment/images/` en el bucket Raw.
Esta ruta aún debe verificarse en el laboratorio; la validación local es sintáctica.

### Alternativa SSH

Descargar labsuser.pem desde Details → Show → Download PEM del laboratorio.
Ejecutar desde el Mac, reemplazando SERVER_PUBLIC_IP por el output real:

```bash
chmod 400 ~/Downloads/labsuser.pem
scp -i ~/Downloads/labsuser.pem /Users/kevrodlm/Downloads/cloud/vibe-aws.tar.gz ec2-user@SERVER_PUBLIC_IP:~/
scp -i ~/Downloads/labsuser.pem ~/Downloads/labsuser.pem ec2-user@SERVER_PUBLIC_IP:~/labsuser.pem
ssh -i ~/Downloads/labsuser.pem ec2-user@SERVER_PUBLIC_IP
```

La clave en el servidor se usa para importar imágenes en los tres agentes por
SSH privado. No incluirla en Git, en el paquete, ni en capturas.

En el servidor, comprobar que terminó su instalación inicial:

```bash
sudo cloud-init status --wait
chmod 400 ~/labsuser.pem
tar -xzf ~/vibe-aws.tar.gz
cd ~/vibe_k8s/vibe
export KUBECONFIG=~/.kube/config
kubectl get nodes -o wide
```

La validación siguiente debe mostrar cuatro nodos Ready. Si falla, revisar
`sudo tail -n 100 /var/log/cloud-init-output.log` y `sudo journalctl -u k3s`.

## 3. Inicializar la aplicación (fase posterior a verificar infraestructura)

```bash
IMAGE_DISTRIBUTION=ssh SSH_PRIVATE_KEY=~/labsuser.pem bash aws/cluster-init.sh RAW_BUCKET_NAME HLS_BUCKET_NAME
kubectl -n vibe get pods -o wide
kubectl -n vibe get hpa,scaledobject
```

El laboratorio comprobó cuatro nodos Ready, la aplicación con S3 real, métricas
de HPA y KEDA, y ensayos medidos. Ver [DEMONSTRATIONS.md](DEMONSTRATIONS.md) para
repetir las pruebas y guardar evidencia. Los resultados dependen de la carga y del
estado del laboratorio; no se garantiza disponibilidad total en cualquier fallo.

Antes de la exposición quedan pendientes: renovación de credenciales S3,
actualización de ServiceMonitor a los microservicios e instalación de monitoreo
si se necesita Prometheus/Grafana. El visor consulta kubectl directamente.
Los PVC locales no proporcionan recuperación de PostgreSQL/Redis en otro nodo;
la cola BLPOP tampoco recupera automáticamente un trabajo interrumpido.

## 4. Evidencias y limpieza

Exportar resultados, capturas y código antes de terminar la sesión. El Sandbox
elimina los datos y recursos al expirar, incluidos los buckets S3.
`bash aws/teardown.sh` vacía los buckets de VIBE y elimina su stack.
