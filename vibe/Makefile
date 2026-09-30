ifeq ($(OS),Windows_NT)
SHELL := C:/Progra~1/Git/bin/bash.exe
else
SHELL := /bin/bash
endif
.SHELLFLAGS := -ec
CLUSTER := vibe
NS := vibe

# Microservices images
MS_IMAGES := vibe-frontend:dev vibe-catalog-api:dev vibe-upload-api:dev vibe-stream-api:dev vibe-worker:dev

.PHONY: help up down cluster cluster-down addons build build-ms load load-ms deploy deploy-ms undeploy status \
        watch logs-ms grafana gen-audio seed compose compose-ms compose-down \
        k6-load k6-stress k6-spike k6-users k6-ramp k6-upload worker-scale \
        chaos-pod chaos-node chaos-db chaos-rolling chaos-oom chaos-oom-restore \
        aws-up aws-down

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------- Todo en uno (Local Microservicios) ----------
up: cluster addons build-ms load-ms deploy-ms ## Crea cluster kind, addons, construye microservicios y despliega todo
	@echo
	@echo "Listo! Abre http://localhost  |  Grafana: make grafana"

down: cluster-down ## Destruye el cluster kind

# ---------- Cluster Local (kind) ----------
cluster: ## Crea el cluster kind (1 control-plane + 3 workers)
	@kind get clusters | grep -q "^$(CLUSTER)$$" || kind create cluster --config k8s/kind-config.yaml
	kubectl cluster-info --context kind-$(CLUSTER)

cluster-down:
	kind delete cluster --name $(CLUSTER)

addons: ## ingress-nginx, metrics-server, KEDA y kube-prometheus-stack
	# ingress-nginx (versión para kind)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	# metrics-server (necesario para el HPA); en kind requiere --kubelet-insecure-tls
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
	  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	# KEDA
	helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	helm repo update >/dev/null
	helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait
	# Prometheus + Grafana
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
	  --set grafana.adminPassword=vibe --set prometheus.prometheusSpec.retention=2d \
	  --set alertmanager.enabled=false --wait --timeout 10m
	kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

# ---------- Construcción de Microservicios ----------
build-ms: ## Construye las 5 imágenes de microservicios
	docker build -t vibe-frontend:dev services/frontend
	docker build -t vibe-catalog-api:dev services/catalog-api
	docker build -t vibe-upload-api:dev services/upload-api
	docker build -t vibe-stream-api:dev services/stream-api
	docker build -t vibe-worker:dev services/worker

load-ms: ## Carga las 5 imágenes de microservicios en kind
	kind load docker-image $(MS_IMAGES) --name $(CLUSTER)

# ---------- Despliegue de Microservicios ----------
deploy-ms: ## Aplica los manifiestos de microservicios
	kubectl apply -f k8s/00-namespace.yaml
	kubectl apply -f k8s/10-config.yaml -f k8s/20-postgres.yaml -f k8s/21-minio.yaml -f k8s/22-redis.yaml
	kubectl -n $(NS) rollout status statefulset/postgres --timeout=180s
	kubectl -n $(NS) rollout status statefulset/minio --timeout=180s
	kubectl apply -f k8s/30-frontend.yaml \
	              -f k8s/31-catalog-api.yaml \
	              -f k8s/32-upload-api.yaml \
	              -f k8s/33-stream-api.yaml \
	              -f k8s/34-worker.yaml \
	              -f k8s/40-ingress.yaml \
	              -f k8s/60-pdb.yaml
	kubectl -n $(NS) rollout status deployment/frontend --timeout=120s
	kubectl -n $(NS) rollout status deployment/catalog-api --timeout=120s
	kubectl -n $(NS) rollout status deployment/upload-api --timeout=120s
	kubectl -n $(NS) rollout status deployment/stream-api --timeout=120s
	kubectl apply -f k8s/50-hpa.yaml -f k8s/51-keda-worker.yaml
	-kubectl apply -f k8s/70-monitoring.yaml

undeploy: ## Elimina el namespace y todos los recursos
	kubectl delete ns $(NS) --ignore-not-found

status: ## Estado de pods, servicios, HPA y KEDA
	kubectl -n $(NS) get pods -o wide
	@echo
	kubectl -n $(NS) get hpa
	@echo
	kubectl -n $(NS) get scaledobject

watch: ## Pods en vivo por nodo
	watch -n1 "kubectl -n $(NS) get pods -o wide --sort-by=.spec.nodeName | awk '{print \$$1, \$$3, \$$7}'"

logs-ms: ## Logs de todos los microservicios en vivo
	kubectl -n $(NS) logs -l 'app in (frontend,catalog-api,upload-api,stream-api,worker)' --tail=50 -f

grafana: ## Port-forward a Grafana (admin / vibe)
	@echo "http://localhost:3000  usuario: admin  clave: vibe"
	kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

# ---------- AWS Academy Sandbox ----------
aws-up: ## Despliega infraestructura en AWS Academy (CloudFormation)
	@./aws/setup.sh

aws-down: ## Vacia buckets y elimina infraestructura en AWS Academy
	@./aws/teardown.sh

# ---------- Datos ----------
gen-audio: ## Genera 200 audios sintéticos en data/audio
	python3 tools/gen_audio.py --count 200 --out data/audio

seed: ## Sube todos los audios a la API (por defecto http://localhost)
	python3 tools/seed.py --api $${API:-http://localhost} --dir data/audio --parallel 10

# ---------- Local sin K8s (Docker Compose) ----------
compose: compose-ms ## Alias para compose-ms

compose-ms: ## Levanta los 5 microservicios con docker compose (puerto 80)
	docker compose -f docker-compose.microservices.yml up --build -d

compose-down: ## Detiene docker compose
	docker compose -f docker-compose.microservices.yml down -v

# ---------- Pruebas k6 ----------
k6-load: ## Carga normal (hasta 300 VUs)
	python3 tools/run_k6.py --name load --env BASE_URL=$${API:-http://localhost} tests/k6/load.js

k6-stress: ## Estrés (hasta 1500 VUs)
	python3 tools/run_k6.py --name stress --env BASE_URL=$${API:-http://localhost} tests/k6/stress.js

k6-spike: ## Pico repentino (0 a 1000 VUs en 10 s)
	python3 tools/run_k6.py --name spike --env BASE_URL=$${API:-http://localhost} tests/k6/spike.js

k6-users: ## Carga fija: make k6-users VUS=500 DURATION=3m
	@[[ "$${VUS:-}" =~ ^[1-9][0-9]*$$ ]] || { echo "Uso: make k6-users VUS=500 DURATION=3m" >&2; exit 2; }
	@[[ "$${DURATION:-}" =~ ^[1-9][0-9]*(ms|s|m|h)$$ ]] || { echo "DURATION inválida (ejemplo: 3m)" >&2; exit 2; }
	python3 tools/run_k6.py --name users --env BASE_URL=$${API:-http://localhost} --env VUS=$${VUS} --env DURATION=$${DURATION} tests/k6/users.js

k6-ramp: ## Carga gradual hasta 1200 VUs
	python3 tools/run_k6.py --name ramp --env BASE_URL=$${API:-http://localhost} tests/k6/ramp.js

k6-upload: ## Subidas concurrentes (escala el worker)
	@test -f "$${UPLOAD_FILE:-data/audio/001 - DJ Replica - Lunar Horizon.mp3}" || { echo "Falta el audio. Ejecuta: make gen-audio" >&2; exit 2; }
	python3 tools/run_k6.py --name upload --env BASE_URL=$${API:-http://localhost} --env UPLOAD_FILE="$${UPLOAD_FILE:-data/audio/001 - DJ Replica - Lunar Horizon.mp3}" tests/k6/upload.js

worker-scale: ## Ejecuta subidas y registra cola/réplicas KEDA (UPLOADS=200)
	python3 tools/run_worker_scale.py --api $${API:-http://localhost} --uploads $${UPLOADS:-200} --ns $(NS)

# ---------- Pruebas de resiliencia (ejecutar deliberadamente) ----------
chaos-pod: ## Elimina pods de API y mide recuperación (INTERVAL=15 TIMES=6)
	$(SHELL) ./chaos/pod-kill.sh $${INTERVAL:-15} $${TIMES:-6} $${APP:-catalog-api}

chaos-node: ## Apaga temporalmente un worker kind (NODE=vibe-worker DOWN=180)
	$(SHELL) ./chaos/node-down.sh $${NODE:-vibe-worker} $${DOWN:-180}

chaos-db: ## Reinicia PostgreSQL y verifica persistencia del PVC
	$(SHELL) ./chaos/db-kill.sh

chaos-rolling: ## Rolling update local y sondeo HTTP (VERSION=v2)
	$(SHELL) ./chaos/rolling-update.sh $${VERSION:-v2}

chaos-oom: ## Fuerza y verifica OOMKilled en worker
	$(SHELL) ./chaos/oom.sh

chaos-oom-restore: ## Restaura el límite normal del worker
	$(SHELL) ./chaos/oom.sh restore
