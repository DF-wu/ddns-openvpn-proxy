SHELL := /usr/bin/env bash

.PHONY: help validate validate-config validate-openvpn-config validate-wireguard-config validate-compose validate-repo up down logs smoke smoke-openvpn smoke-wireguard

help:
	@printf '%s\n' \
	  'make validate                Validate the compose stack and VPN config contract' \
	  'make validate-config         Validate VPN config (default: OpenVPN, set VPN_TYPE=wireguard)' \
	  'make validate-openvpn-config Validate ./config/openvpn/ (or pass CONFIG=...)' \
	  'make validate-wireguard-config Validate ./config/wireguard/ (or pass CONFIG=...)' \
	  'make validate-compose        Validate docker-compose.yml with example inputs' \
	  'make validate-repo           Validate example configs and Compose contract' \
	  'make up                      Start the DDNS-aware Gluetun stack' \
	  'make down                    Stop the stack' \
	  'make logs                    Tail the Gluetun and DDNS watcher logs' \
	  'make smoke                   Run all DDNS render/restart smoke tests' \
	  'make smoke-openvpn           Run OpenVPN smoke test' \
	  'make smoke-wireguard         Run WireGuard smoke test'

validate: validate-config validate-compose

validate-repo:
	@$(MAKE) validate-openvpn-config CONFIG=./examples/openvpn/custom.ovpn
	@$(MAKE) validate-wireguard-config CONFIG=./examples/wireguard/wg0.conf
	@$(MAKE) validate-compose

validate-config:
	@scripts/validate-vpn-config.sh "$(CONFIG)"

validate-openvpn-config:
	@VPN_TYPE=openvpn scripts/validate-vpn-config.sh "$(CONFIG)"

validate-wireguard-config:
	@VPN_TYPE=wireguard scripts/validate-vpn-config.sh "$(CONFIG)"

validate-compose:
	@scripts/validate-compose.sh

up:
	docker compose up -d

down:
	docker compose down --remove-orphans

logs:
	docker compose logs -f gluetun vproxy ddns-watcher

smoke: smoke-openvpn smoke-wireguard

smoke-openvpn:
	@VPN_TYPE=openvpn tests/e2e/smoke.sh

smoke-wireguard:
	@VPN_TYPE=wireguard tests/e2e/smoke.sh
