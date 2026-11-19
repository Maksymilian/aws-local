.DEFAULT_GOAL := help
EXAMPLES := $(sort $(wildcard examples/0*.sh))

.PHONY: help up down restart logs status examples java

help: ## Show available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Start LocalStack and wait until all resources are provisioned
	docker compose up -d --wait

down: ## Stop LocalStack and remove its volume
	docker compose down -v

restart: down up ## Start from a clean slate (re-runs provisioning)

logs: ## Follow LocalStack logs
	docker compose logs -f localstack

status: ## Show running services and the init hook result
	@curl -sf localhost:4566/_localstack/health | jq '{version, running: [.services | to_entries[] | select(.value == "running") | .key]}'
	@curl -sf localhost:4566/_localstack/init/ready | jq -c '.scripts[]'

examples: ## Run every example script in order
	@for f in $(EXAMPLES); do printf '\n\033[1m##### %s\033[0m\n' "$$f"; ./$$f || exit 1; done

java: ## Run the Java SDK client against LocalStack
	cd java-client && mvn -q compile exec:java
