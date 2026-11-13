# =============================================================================
# Makefile - every common task of the devops-cicd-app project.
#
#   make help      -> list all targets
#   make setup     -> create the local virtualenv and install everything
#   make test      -> run the test suite with coverage
#   make lint      -> ruff + black check + shellcheck
#   make run       -> run the app locally (Flask dev server)
#   make up        -> start the whole stack with Docker Compose
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help setup venv install run lint lint-ci format test test-cov coverage \
        docker-build docker-build-unoptimized docker-up docker-down docker-logs \
        docker-shell measure-images migrate seed clean ci

PY      := python3
VENV    := .venv
BIN     := $(VENV)/bin
PIP     := $(BIN)/pip
COMPOSE := docker compose

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# --------------------------------------------------------------------------- #
# Local development
# --------------------------------------------------------------------------- #
venv: ## Create the virtualenv
	$(PY) -m venv $(VENV)
	@echo "Virtualenv created at $(VENV)"

install: ## Install runtime + development dependencies
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt -r requirements-dev.txt

setup: venv install ## Full local setup (venv + dependencies)
	@chmod +x scripts/*.sh 2>/dev/null || true   # the exec bit can be lost on copy/zip

run: ## Run the app on http://127.0.0.1:8000
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi
	APP_ENV=development $(BIN)/python wsgi.py

migrate: ## Create the database tables
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi
	$(BIN)/flask --app wsgi init-db

seed: ## Insert demo users
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi
	$(BIN)/flask --app wsgi seed-db --count 10

# --------------------------------------------------------------------------- #
# Quality gates
# --------------------------------------------------------------------------- #
lint: ## Run every static check (ruff, black, shellcheck)
	$(BIN)/ruff check .
	$(BIN)/black --check .
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S style scripts/*.sh \
		|| echo "shellcheck not installed - skipping"

# The exact four commands the CI "1-3 | Checkout, Lint & Test" job runs, in the
# same order, using the same pinned versions from requirements-dev.txt.
# Run this before pushing - it catches what GitHub Actions would fail on.
lint-ci: ## Reproduce the CI lint job exactly (pinned ruff/black/shellcheck)
	$(BIN)/ruff check . --output-format=concise
	$(BIN)/black --check --diff .
	$(BIN)/ruff check . --select S --output-format=concise
	$(BIN)/shellcheck --version
	$(BIN)/shellcheck -S style scripts/*.sh
	@echo "✅ CI lint job will pass"

format: ## Auto-format the code
	$(BIN)/ruff check . --fix
	$(BIN)/black .

test: ## Run the test suite
	$(BIN)/pytest -v --color=yes

test-cov: ## Run the test suite and open the HTML coverage report
	$(BIN)/pytest --cov=app --cov-report=html --cov-report=term-missing
	@echo "HTML report: htmlcov/index.html"

coverage: ## Coverage summary only
	$(BIN)/pytest -q --cov=app --cov-report=term

ci: lint test ## Everything the CI pipeline runs before the image build

# --------------------------------------------------------------------------- #
# Docker
# --------------------------------------------------------------------------- #
docker-build: ## Build the optimised multi-stage image
	docker build -f Dockerfile -t devops-cicd-app:optimized .

docker-build-unoptimized: ## Build the baseline (unoptimised) image for comparison
	docker build -f Dockerfile.unoptimized -t devops-cicd-app:unoptimized .

docker-up: ## Start the development stack (app + postgres + nginx)
	$(COMPOSE) up -d --build
	@echo "Application: http://localhost:$${NGINX_HTTP_PORT:-8080}"

docker-down: ## Stop the development stack (keeps the database volume)
	$(COMPOSE) down

docker-logs: ## Follow the application logs
	$(COMPOSE) logs -f app

docker-shell: ## Open a shell inside the running app container
	$(COMPOSE) exec app /bin/bash

measure-images: ## Measure the image-size reduction (needs Docker)
	./scripts/measure-image-size.sh

# --------------------------------------------------------------------------- #
# Housekeeping
# --------------------------------------------------------------------------- #
clean: ## Remove caches and build artefacts
	rm -rf .pytest_cache .ruff_cache htmlcov coverage.xml reports __pycache__
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	@echo "Clean."
