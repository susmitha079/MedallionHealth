# ============================================================
# MedallionHealth – Developer Makefile
# Usage: make <target>
# ============================================================

.PHONY: help setup build test lint clean \
        infra-init infra-plan infra-apply \
        services-build services-test \
        kafka-topics kafka-schemas \
        lakehouse-validate \
        dbt-run dbt-test dbt-docs \
        airflow-up airflow-down \
        ml-train ml-serve \
        generator-start generator-stop \
        docker-up docker-down \
        k8s-deploy k8s-teardown \
        fmt check-contracts

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Colours ────────────────────────────────────────────────
GREEN  := \033[0;32m
YELLOW := \033[0;33m
CYAN   := \033[0;36m
RESET  := \033[0m

# ── Variables ──────────────────────────────────────────────
ENV          ?= local
AWS_REGION   ?= us-east-1
TF_ENV_DIR   := infrastructure/terraform/environments/$(AWS_REGION)
KAFKA_BROKER ?= localhost:9092
SCHEMA_REG   ?= http://localhost:8081
DBT_PROFILE  ?= medallionhealth_dev
GENERATOR_RATE ?= 100  # events per second

help: ## Show this help
	@echo ""
	@echo "$(CYAN)MedallionHealth – Available Commands$(RESET)"
	@echo "════════════════════════════════════════"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ \
		{ printf "  $(GREEN)%-30s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

# ── Setup ──────────────────────────────────────────────────
setup: ## Bootstrap local development environment
	@echo "$(CYAN)Setting up development environment...$(RESET)"
	@which java   >/dev/null 2>&1 || (echo "ERROR: Java 17+ required" && exit 1)
	@which python >/dev/null 2>&1 || (echo "ERROR: Python 3.11+ required" && exit 1)
	@which docker >/dev/null 2>&1 || (echo "ERROR: Docker required" && exit 1)
	@which terraform >/dev/null 2>&1 || (echo "ERROR: Terraform 1.6+ required" && exit 1)
	@which kubectl >/dev/null 2>&1 || (echo "ERROR: kubectl required" && exit 1)
	@cp -n .env.example .env 2>/dev/null || true
	@pip install -r data-generator/requirements.txt --quiet
	@pip install -r ml/serving/requirements.txt --quiet
	@pip install -r llm/healthcare-assistant/requirements.txt --quiet
	@echo "$(GREEN)✓ Setup complete. Edit .env before running services.$(RESET)"

# ── Docker local stack ──────────────────────────────────────
docker-up: ## Start full local stack (Kafka, Postgres, Schema Registry)
	@echo "$(CYAN)Starting local stack...$(RESET)"
	docker compose -f docker-compose.yml up -d
	@echo "$(GREEN)✓ Local stack running$(RESET)"
	@echo "  Kafka:           localhost:9092"
	@echo "  Schema Registry: localhost:8081"
	@echo "  Kafka UI:        http://localhost:8080"
	@echo "  Airflow:         http://localhost:8888"
	@echo "  Postgres:        localhost:5432"

docker-down: ## Stop local stack
	docker compose -f docker-compose.yml down

docker-clean: ## Stop local stack and remove volumes
	docker compose -f docker-compose.yml down -v

# ── Services (Spring Boot) ──────────────────────────────────
services-build: ## Build all Spring Boot microservices
	@echo "$(CYAN)Building all services...$(RESET)"
	@for svc in patient-service appointment-service bed-management-service billing-service audit-service; do \
		echo "  Building $$svc..."; \
		cd services/$$svc && ./mvnw package -DskipTests -q && cd ../..; \
	done
	@echo "$(GREEN)✓ All services built$(RESET)"

services-test: ## Run all service unit + integration tests
	@for svc in patient-service appointment-service bed-management-service billing-service audit-service; do \
		echo "$(CYAN)Testing $$svc...$(RESET)"; \
		cd services/$$svc && ./mvnw test && cd ../..; \
	done

services-lint: ## Lint all Java services (Checkstyle + SpotBugs)
	@for svc in patient-service appointment-service bed-management-service billing-service audit-service; do \
		cd services/$$svc && ./mvnw checkstyle:check spotbugs:check -q && cd ../..; \
	done

# ── Kafka ───────────────────────────────────────────────────
kafka-topics: ## Create all Kafka topics from registry
	@echo "$(CYAN)Creating Kafka topics...$(RESET)"
	python data-platform/kafka/scripts/create_topics.py \
		--registry data-platform/kafka/schemas/topic-registry.yaml \
		--broker $(KAFKA_BROKER)
	@echo "$(GREEN)✓ Topics created$(RESET)"

kafka-schemas: ## Register all Avro schemas in Schema Registry
	@echo "$(CYAN)Registering schemas...$(RESET)"
	python data-platform/kafka/scripts/register_schemas.py \
		--schema-dir data-platform/kafka/schemas \
		--registry $(SCHEMA_REG)
	@echo "$(GREEN)✓ Schemas registered$(RESET)"

check-contracts: ## Validate all event schemas against data contracts
	@echo "$(CYAN)Validating data contracts...$(RESET)"
	python data-platform/kafka/scripts/validate_contracts.py \
		--contracts docs/data-contracts \
		--schemas data-platform/kafka/schemas
	@echo "$(GREEN)✓ All contracts valid$(RESET)"

# ── Data Generator ──────────────────────────────────────────
generator-start: ## Start data simulation (default: 100 events/sec)
	@echo "$(CYAN)Starting data generator at $(GENERATOR_RATE) events/sec...$(RESET)"
	python data-generator/src/simulator/main.py \
		--rate $(GENERATOR_RATE) \
		--broker $(KAFKA_BROKER) \
		--hospitals 50 &
	@echo "$(GREEN)✓ Generator running. Stop with: make generator-stop$(RESET)"

generator-stop: ## Stop data generator
	@pkill -f "simulator/main.py" 2>/dev/null || echo "Generator not running"

generator-status: ## Show generator API status
	@curl -s http://localhost:8090/api/v1/simulator/status | python -m json.tool

# ── Lakehouse ───────────────────────────────────────────────
lakehouse-validate: ## Validate Bronze/Silver/Gold partition health
	@echo "$(CYAN)Validating lakehouse partitions...$(RESET)"
	python data-platform/lakehouse/scripts/validate_partitions.py --env $(ENV)

# ── dbt ─────────────────────────────────────────────────────
dbt-run: ## Run all dbt models
	@cd data-platform/warehouse/dbt && dbt run --profiles-dir . --profile $(DBT_PROFILE)

dbt-test: ## Run all dbt tests
	@cd data-platform/warehouse/dbt && dbt test --profiles-dir . --profile $(DBT_PROFILE)

dbt-docs: ## Generate and serve dbt documentation
	@cd data-platform/warehouse/dbt && \
		dbt docs generate --profiles-dir . --profile $(DBT_PROFILE) && \
		dbt docs serve --port 8085

dbt-lineage: ## Show dbt model lineage for a specific model
	@read -p "Model name: " model; \
	cd data-platform/warehouse/dbt && \
		dbt ls --select "+$$model+" --profiles-dir . --profile $(DBT_PROFILE)

# ── Airflow ─────────────────────────────────────────────────
airflow-up: ## Start Airflow (local)
	@cd data-platform/orchestration/airflow && \
		docker compose up -d
	@echo "$(GREEN)✓ Airflow UI: http://localhost:8888$(RESET)"

airflow-down: ## Stop Airflow
	@cd data-platform/orchestration/airflow && docker compose down

# ── ML ──────────────────────────────────────────────────────
ml-train: ## Train ML models (readmission + workload)
	@echo "$(CYAN)Training readmission prediction model...$(RESET)"
	python ml/readmission-prediction/src/training/train.py --env $(ENV)
	@echo "$(CYAN)Training workload optimization model...$(RESET)"
	python ml/workload-optimization/src/training/train.py --env $(ENV)

ml-serve: ## Start ML model serving API
	@uvicorn ml.serving.src.main:app --host 0.0.0.0 --port 8001 --reload

ml-test: ## Run ML pipeline tests
	@pytest ml/readmission-prediction/tests -v
	@pytest ml/workload-optimization/tests -v
	@pytest ml/serving/tests -v

# ── LLM Assistant ───────────────────────────────────────────
llm-serve: ## Start LLM Healthcare Assistant API
	@uvicorn llm.healthcare-assistant.src.api.main:app --host 0.0.0.0 --port 8002 --reload

llm-test: ## Run LLM assistant tests
	@pytest llm/healthcare-assistant/tests -v

# ── Frontend ────────────────────────────────────────────────
frontend-dev: ## Start Next.js dev server
	@cd frontend/dashboard && npm run dev

frontend-build: ## Build Next.js for production
	@cd frontend/dashboard && npm run build

# ── Infrastructure ──────────────────────────────────────────
infra-init: ## Initialize Terraform for target region
	@echo "$(CYAN)Initializing Terraform for $(AWS_REGION)...$(RESET)"
	cd $(TF_ENV_DIR) && terraform init

infra-plan: ## Terraform plan for target region
	cd $(TF_ENV_DIR) && terraform plan -out=tfplan

infra-apply: ## Terraform apply (requires prior plan)
	cd $(TF_ENV_DIR) && terraform apply tfplan

infra-destroy: ## DANGER: Destroy all infrastructure in target region
	@read -p "Type region name to confirm destruction ($(AWS_REGION)): " confirm; \
	[ "$$confirm" = "$(AWS_REGION)" ] && cd $(TF_ENV_DIR) && terraform destroy

# ── Kubernetes ──────────────────────────────────────────────
k8s-namespaces: ## Create all K8s namespaces
	kubectl apply -f infrastructure/k8s/namespaces/

k8s-deploy: ## Deploy all services to Kubernetes
	@echo "$(CYAN)Deploying to Kubernetes...$(RESET)"
	kubectl apply -f infrastructure/k8s/services/
	kubectl apply -f infrastructure/k8s/streaming/
	kubectl apply -f infrastructure/k8s/data-platform/
	kubectl apply -f infrastructure/k8s/ml/
	kubectl apply -f infrastructure/k8s/llm/
	kubectl apply -f infrastructure/k8s/monitoring/

k8s-status: ## Show all pod statuses across namespaces
	@for ns in services streaming data-platform ml llm monitoring; do \
		echo "$(CYAN)Namespace: $$ns$(RESET)"; \
		kubectl get pods -n $$ns 2>/dev/null || echo "  (empty)"; \
	done

# ── CI / Lint ───────────────────────────────────────────────
fmt: ## Format all code (Java, Python, SQL)
	@find services -name "*.java" | xargs google-java-format -r 2>/dev/null || true
	@black data-generator ml llm 2>/dev/null || true
	@sqlfluff fix data-platform/warehouse/dbt/models 2>/dev/null || true

lint: ## Lint all code
	@cd services/patient-service && ./mvnw checkstyle:check -q
	@flake8 data-generator ml llm --max-line-length=120
	@sqlfluff lint data-platform/warehouse/dbt/models --dialect redshift

# ── Full CI ─────────────────────────────────────────────────
ci: lint services-test dbt-test ml-test llm-test check-contracts ## Run full CI pipeline locally
	@echo "$(GREEN)✓ All CI checks passed$(RESET)"

# ── Clean ───────────────────────────────────────────────────
clean: ## Clean all build artifacts
	@find services -name "target" -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.pyc" -delete 2>/dev/null || true
	@find data-platform/warehouse/dbt -name "target" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "$(GREEN)✓ Clean$(RESET)"
