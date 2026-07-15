SHELL := /bin/sh

.PHONY: help check lint-docs validate validate-compose test test-container up pull down restart status logs config clean

help:
	@printf '%s\n' \
	  'make check      Run every repository validation and test' \
	  'make validate   Validate Compose plus your selected VPN profile' \
	  'make up         Validate, pull, and start the production stack' \
	  'make status     Show service and DDNS runtime status' \
	  'make logs       Follow VPN, proxy, and DDNS logs' \
	  'make restart    Recreate services after configuration changes' \
	  'make down       Stop services; keep the runtime state volume' \
	  'make clean      Stop services and delete the runtime state volume'

check: lint-docs validate-compose test test-container

lint-docs:
	docker run --rm -v "$(CURDIR):/workdir:ro" -w /workdir \
	  davidanson/markdownlint-cli2:v0.18.1 README.md 'docs/**/*.md'

validate: validate-compose
	docker compose run --rm --no-deps ddns-init validate

validate-compose:
	@scripts/validate-compose.sh

test:
	@tests/run.sh
	@tests/compose-validation.sh
	@tests/compat-watcher.sh

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
	docker compose logs -f --tail=100 gluetun vproxy ddns-watcher docker-socket-proxy

config:
	docker compose config
