#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

if [[ -f "$repo_root/.env" ]]; then
  docker compose --env-file "$repo_root/.env" -f "$repo_root/docker-compose.yml" config -q
  printf 'Docker Compose validation passed using %s/.env.\n' "$repo_root"
  exit 0
fi

mkdir -p "$temp_dir/config/openvpn" "$temp_dir/state/openvpn"
cp "$repo_root/examples/openvpn/custom.ovpn" "$temp_dir/config/openvpn/client.ovpn"

cat >"$temp_dir/.env" <<EOF
TZ=UTC
OPENVPN_CONFIG_DIR=$temp_dir/config
OPENVPN_SOURCE_CONFIG=$temp_dir/config/openvpn/client.ovpn
STATE_DIR=$temp_dir/state
DDNS_HOSTNAME=vpn.example.com
DDNS_POLL_SECONDS=60
DDNS_COOLDOWN_SECONDS=15
DDNS_RESOLVER=
DDNS_OVERRIDE_IP=203.0.113.10
HTTP_PROXY_PORT=8888
GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy
WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest
GLUETUN_IMAGE=qmcgaw/gluetun:latest
EOF

docker compose --env-file "$temp_dir/.env" -f "$repo_root/docker-compose.yml" config -q
printf 'Docker Compose validation passed.\n'
