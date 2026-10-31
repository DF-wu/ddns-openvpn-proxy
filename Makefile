SHELL := /bin/sh

# The Compose CLI honours COMPOSE_FILE from .env, so every target below works
# for whichever backend stack .env selects (docker-compose.yml by default).

.PHONY: help check lint-docs shellcheck validate validate-compose test test-container up pull down restart status logs config clean

help:
	@printf '%s\n' \
	  'make check            Run every repository validation and test' \
	  'make validate         Validate Compose plus your selected VPN profile' \
	  'make up               Validate, pull, and start the selected backend stack' \
	  'make status           Show service and DDNS runtime status' \
	  'make logs             Follow all service logs' \
	  'make restart          Recreate services after configuration changes' \
	  'make down             Stop services; keep the runtime state volume' \
	  'make clean            Stop services and delete the runtime state volume' \
	  'make shellcheck       Static-check shell scripts with the pinned ShellCheck image' \
	  'make test             Offline suites: helper behaviour, Compose contract, compat watcher' \
	  'make test-container   Real container contract for every backend (needs Docker)'

check: lint-docs validate-compose test test-container

lint-docs:
	docker run --rm -v "$(CURDIR):/workdir:ro" -w /workdir \
	  davidanson/markdownlint-cli2:v0.18.1 README.md CHANGELOG.md 'docs/**/*.md'

shellcheck:
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0 \
	  -s sh scripts/*.sh scripts/lib/*.sh scripts/adapters/*.sh tests/*.sh
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0 \
	  -s bash compat/watcher/*.sh

validate: validate-compose
	docker compose run --rm --no-deps ddns-init validate

validate-compose:
	@scripts/validate-compose.sh

test:
	@tests/run.sh

test-container:
	@tests/container-contract.sh

pull:
	docker compose pull

up: validate pull
	docker compose up -d --wait --wait-timeout 180

down:
	docker compose down --remove-orphans

clean:
	docker compose down --remove-orphans --volumes

restart: validate
	docker compose up -d --force-recreate --wait --wait-timeout 180

status:
	@docker compose ps
	@printf '\nDDNS watcher:\n'
	@docker compose logs --tail=10 ddns-watcher

logs:
	docker compose logs -f --tail=100

config:
	docker compose config
