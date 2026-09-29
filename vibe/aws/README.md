# VIBE en AWS Academy Cloud Foundations Sandbox

Preparación para el entorno confirmado: us-east-1, LabInstanceProfile/LabRole,
clave vockey, hasta nueve EC2 encendidas y limpieza completa al finalizar la sesión.
El bastión y el IDE del laboratorio son recursos externos a VIBE: conservarlos.

## 1. Copiar la versión corregida a CloudShell

Subir `vibe-aws.tar.gz` con Actions → Upload file. No clonar una revisión antigua
del repositorio: este paquete incluye los cambios locales pendientes de publicar.

```bash
tar -xzf vibe-aws.tar.gz
cd vibe_k8s/vibe
aws cloudformation validate-template --region us-east-1 --template-body file://aws/cloudformation.yaml
bash aws/setup.sh vockey
```

setup.sh comprueba el perfil, la clave y una VPC predeterminada con tres subredes
públicas. Si no existe esa red, se detiene antes de crear recursos; hay que elegir
otra red y adaptar sus parámetros. La plantilla crea cuatro EC2 Amazon Linux 2023,
un security group, Classic ELB y dos buckets S3. No instala la app todavía.

Guardar los outputs ServerPublicIP, RawBucketName, HlsBucketName y LoadBalancerURL.
CloudFormation puede terminar antes de que finalice cloud-init/k3s en las EC2.

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
