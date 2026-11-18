# D1 chain simulator - environment operation.
#
# Run `make` with no arguments to see every available command.

.DEFAULT_GOAL := help
.PHONY: help up up-local infra deploy-api deploy-worker deploy-web destroy-aws up-stores start down destroy shell exec test test-unit test-integration \
        logs ps require-running

# Every command sees the central profile, so exec, logs and ps work on the
# central services in all-local mode.
COMPOSE := docker compose --profile central

help: ## Show this help
	@echo ""
	@echo "  D1 Chain Simulator - two stores and a central site"
	@echo ""
	@echo "  make up            Bring up the WHOLE environment: run the four pipelines in order"
	@echo "                     (infra, API, worker, dashboard), then start the two stores locally,"
	@echo "                     delivering to it. Needs a Learner Lab session. See DEPLOY.md."
	@echo "  make up-local      The original mode: everything on this machine, central site included"
	@echo "  make start         Alias for 'make up'"
	@echo "  make infra         Infrastructure pipeline only: machines, network, balancer, ECR repos"
	@echo "                     (infraestructura/deploy.sh). Deploys no code."
	@echo "  make deploy-api    API pipeline only: build, test, push, roll the API machines"
	@echo "  make deploy-worker Worker pipeline only: build, push, update the worker machine via SSM"
	@echo "  make deploy-web    Dashboard pipeline only: build, push, roll the dashboard machines"
	@echo "  make up-stores     Start ONLY the stores and the payment gateway, delivering sales to"
	@echo "                     the central site on AWS. Run 'make infra' first."
	@echo "  make down          DESTRUCTIVE. Stop and remove LOCAL containers, images, networks, VOLUMES and orphans."
	@echo "                     This wipes BOTH store databases AND the central database: every"
	@echo "                     recorded sale is lost and the seed data is recreated on the next"
	@echo "                     'make up'."
	@echo "  make destroy       DESTRUCTIVE. Tear down the WHOLE environment: delete the central site on AWS"
	@echo "                     and its ECR images (infraestructura/destroy.sh), then everything 'make down' does."
	@echo "                     Stops without touching local data if the AWS step fails."
	@echo "  make shell CONTAINER=<name>"
	@echo "                     Open an interactive shell inside a running container."
	@echo "                     Example: make shell CONTAINER=store-1-register-1"
	@echo "  make exec          Alias for 'make shell'"
	@echo "  make logs          Follow the logs of every service"
	@echo "  make logs CONTAINER=store-1-sync"
	@echo "                     Follow one service only. Use this to watch the batching:"
	@echo "                     each batch logs how many invoices went out and why."
	@echo "  make ps            Show the state of every service"
	@echo "  make test          Run the unit tests and the integration tests"
	@echo "  make test-unit     Run only the unit tests (backend, gateway, forwarder, central API)"
	@echo "  make test-integration"
	@echo "                     Run only the integration tests, from a register of each store"
	@echo ""
	@echo "  --- Stores -------------------------------------------------------"
	@echo "  Store 1, register 1:  http://localhost:8081"
	@echo "  Store 1, register 2:  http://localhost:8082"
	@echo "  Store 2, register 1:  http://localhost:8083"
	@echo "  Store 2, register 2:  http://localhost:8084"
	@echo ""
	@echo "  You reach a store's web site THROUGH one of its registers, the way a"
	@echo "  cashier does. Neither frontend container publishes a host port."
	@echo ""
	@echo "  Store 1 backend:   http://localhost:18000/health   (docs at /docs)"
	@echo "  Store 2 backend:   http://localhost:18001/health   (docs at /docs)"
	@echo "  Store 1 database:  localhost:55432                 (user/db 'store')"
	@echo "  Store 2 database:  localhost:55433                 (user/db 'store')"
	@echo ""
	@echo "  --- Central site (head office) -----------------------------------"
	@echo "  Dashboard:         http://localhost:8080"
	@echo "  Central API:       http://localhost:18100/health   (docs at /docs)"
	@echo "  Central database:  localhost:33306                 (user/db 'central', MySQL)"
	@echo ""
	@echo "  Host ports avoid the usual 5432, 8000 and 3306 so they do not clash"
	@echo "  with a PostgreSQL, API or MySQL you may already be running. Change"
	@echo "  them in .env."
	@echo ""
	@echo "  NOTE: fase 1 uses some of these same ports. Do not run both phases"
	@echo "  at once - run 'make down' in fase1/completo first."
	@echo ""
	@echo "  A sale takes up to about a minute to reach the dashboard: stores ship"
	@echo "  in batches of 10 invoices or every 60 seconds, whichever comes first."
	@echo "  See BATCH_MAX_AGE_SECONDS in .env to shorten it for a demonstration."
	@echo ""

# Cloud mode: each folder has its own pipeline, as if each were its own repository.
# They run one after another, in the order DEPLOY.md explains: the infrastructure
# first (it creates the machines, the ECR repositories and .env.cloud), then one
# pipeline per service, then the stores. Sub-makes keep the order explicit even
# under 'make -j'.
up: ## Bring up the whole environment: four pipelines on AWS + stores locally
	$(MAKE) infra
	$(MAKE) deploy-api
	$(MAKE) deploy-worker
	$(MAKE) deploy-web
	$(MAKE) up-stores

infra: ## Infrastructure pipeline: machines, network, balancer, ECR repositories
	./infraestructura/deploy.sh

deploy-api: ## API pipeline: build, test, push to ECR, roll the API machines
	./central-api/deploy.sh

deploy-worker: ## Worker pipeline: build, push to ECR, update its machine through SSM
	./central-worker/deploy.sh

deploy-web: ## Dashboard pipeline: build, push to ECR, roll the dashboard machines
	./central-web/deploy.sh

# The original all-local mode: both stores AND the central site as containers on this machine.
up-local: ## Build and start everything locally, central site included (no AWS)
	$(COMPOSE) up -d --build

# Stores only: no central-* container. Both env files are listed because naming
# any --env-file stops Compose from loading .env on its own.
up-stores: ## Build and start the stores only, connected to the central site on AWS
	@test -f .env.cloud || { \
		echo "Error: .env.cloud not found."; \
		echo "Run 'make infra' first: it creates the central site on AWS"; \
		echo "and writes the address the stores must deliver to."; \
		exit 1; \
	}
	docker compose --env-file .env --env-file .env.cloud up -d --build

start: up

down: ## Stop and remove local containers, images, networks, volumes and orphans
	$(COMPOSE) down --rmi all -v --remove-orphans

# Skips the AWS step when nothing was deployed from this folder, so it also works in local-only mode.
# destroy.sh deletes the infrastructure and the three ECR repositories with their images.
destroy-aws: ## Delete the central site and its ECR repositories on AWS (infraestructura/destroy.sh)
	@if [ -f infraestructura/terraform.tfstate ]; then \
		./infraestructura/destroy.sh; \
	else \
		echo "==> No Terraform state: nothing deployed on AWS from here, skipping."; \
	fi

# AWS first: if it fails (for example expired credentials) make stops and nothing local is deleted.
destroy: destroy-aws down ## Tear down the whole environment: AWS site + every local container, volume and image

shell: ## Open a shell inside a container: make shell CONTAINER=store-1-register-1
ifndef CONTAINER
	@echo "Error: CONTAINER is required."
	@echo "Usage: make shell CONTAINER=<name>"
	@echo ""
	@echo "Available containers:"
	@echo "  Store 1: store-1-register-1, store-1-register-2, store-1-backend,"
	@echo "           store-1-frontend, store-1-postgres, store-1-sync"
	@echo "  Store 2: store-2-register-1, store-2-register-2, store-2-backend,"
	@echo "           store-2-frontend, store-2-postgres, store-2-sync"
	@echo "  Central: central-api, central-web, central-mysql"
	@echo "  External: payment-gateway"
	@exit 1
endif
	@$(COMPOSE) exec $(CONTAINER) sh -c 'command -v bash >/dev/null && exec bash || exec sh'

exec: shell

# The tests run inside the running containers, so they need the environment up.
# Failing here with a clear message beats a confusing "service not running"
# error from Compose, and keeps each target single-purpose: 'test' tests, it
# does not deploy.
require-running:
	@$(COMPOSE) ps --status running --services 2>/dev/null | grep -q . || { \
		echo "Error: the environment is not running."; \
		echo "Start it first with 'make up-local', then run the tests again."; \
		exit 1; \
	}

test: test-unit test-integration ## Run the full test suite

test-unit: require-running ## Run the unit tests inside the service containers
	@echo "==> Store backend unit tests"
	@$(COMPOSE) exec -T store-1-backend python -m pytest app -q
	@echo "==> Payment gateway unit tests"
	@$(COMPOSE) exec -T payment-gateway python -m pytest app -q
	@echo "==> Forwarder unit tests"
	@$(COMPOSE) exec -T store-1-sync python -m pytest app -q
	@echo "==> Central API unit tests"
	@$(COMPOSE) exec -T central-api python -m pytest app -q

test-integration: require-running ## Run the integration tests from a register of each store
	@echo "==> Integration tests from store-1-register-1"
	@$(COMPOSE) exec -T store-1-register-1 python integration_tests.py
	@echo "==> Integration tests from store-2-register-1"
	@$(COMPOSE) exec -T store-2-register-1 python integration_tests.py
	@echo "==> Consolidation tests (store to head office)"
	@$(COMPOSE) exec -T store-1-sync python -m app.consolidation_tests
	@echo "==> Delivery resilience (head office unavailable)"
	@./scripts/resilience_test.sh

logs: ## Follow the logs of every service, or of one: make logs CONTAINER=store-1-sync
ifdef CONTAINER
	$(COMPOSE) logs -f $(CONTAINER)
else
	$(COMPOSE) logs -f
endif

ps: ## Show the state of every service
	$(COMPOSE) ps
