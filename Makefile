SHELL := /usr/bin/env bash

.PHONY: help validate validate-config validate-compose validate-repo up down logs smoke

help:
	@printf '%s\n' \
	  'make validate         Validate the compose stack and OpenVPN config contract' \
	  'make validate-config  Validate ./config/openvpn/ (or pass CONFIG=...)' \
	  'make validate-compose Validate docker-compose.yml with example inputs' \
	  'make up               Start the DDNS-aware Gluetun stack' \
	  'make down             Stop the stack' \
	  'make logs             Tail the Gluetun and DDNS watcher logs' \
	  'make smoke            Run the DDNS render/restart smoke test'

validate: validate-config validate-compose

validate-repo:
	@$(MAKE) validate CONFIG=./examples/openvpn/custom.ovpn

validate-config:
	@scripts/validate-openvpn-config.sh "$(CONFIG)"

validate-compose:
	@scripts/validate-compose.sh

up:
	docker compose up -d

down:
	docker compose down --remove-orphans

logs:
	docker compose logs -f gluetun ddns-watcher

smoke:
	@tests/e2e/smoke.sh
