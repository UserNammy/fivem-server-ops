# Day-to-day operations shortcuts. Run `make help`.
COMPOSE ?= docker compose
SHELL_SCRIPTS := docker/*.sh backup/*.sh
DOCKERFILES := docker/Dockerfile backup/Dockerfile monitoring/exporter/Dockerfile

.DEFAULT_GOAL := help
.PHONY: help up up-monitoring down ps logs build backup backups restore-latest lint test rules

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

build: ## Build all images
	$(COMPOSE) --profile monitoring build

up: ## Start game server, database and backups
	$(COMPOSE) up -d

up-monitoring: ## Start everything including exporter, Prometheus and Grafana
	$(COMPOSE) --profile monitoring up -d

down: ## Stop the stack (volumes are kept)
	$(COMPOSE) --profile monitoring down

ps: ## Show service status and health
	$(COMPOSE) --profile monitoring ps

logs: ## Follow FXServer logs
	$(COMPOSE) logs -f --tail=200 fxserver

backup: ## Run a backup now
	$(COMPOSE) exec backup /usr/local/bin/backup.sh

backups: ## List local backups
	$(COMPOSE) --profile restore run --rm restore --list

restore-latest: ## Stop fxserver and restore the latest local backup
	$(COMPOSE) stop fxserver
	$(COMPOSE) --profile restore run --rm restore latest
	$(COMPOSE) start fxserver

lint: ## shellcheck + hadolint (via docker)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:stable -x $(SHELL_SCRIPTS)
	@for f in $(DOCKERFILES); do echo "hadolint $$f"; docker run --rm -i hadolint/hadolint < $$f || exit 1; done

rules: ## Check and unit-test Prometheus alert rules
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/rules:ro" -w /rules --entrypoint promtool prom/prometheus:v2.54.1 check rules alerts.yml
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/rules:ro" -w /rules --entrypoint promtool prom/prometheus:v2.54.1 test rules alerts_test.yml

test: ## Run exporter unit tests
	cd monitoring/exporter && python -m pytest -v
