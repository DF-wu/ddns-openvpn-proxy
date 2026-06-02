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

mkdir -p "$temp_dir/config/openvpn" "$temp_dir/config/wireguard" "$temp_dir/state/openvpn" "$temp_dir/state/wireguard"
cp "$repo_root/examples/openvpn/custom.ovpn" "$temp_dir/config/openvpn/client.ovpn"
cp "$repo_root/examples/wireguard/wg0.conf" "$temp_dir/config/wireguard/wg0.conf"

cat >"$temp_dir/.env" <<EOF
TZ=UTC
OPENVPN_CONFIG_DIR=$temp_dir/config
OPENVPN_SOURCE_CONFIG=$temp_dir/config/openvpn/client.ovpn
WIREGUARD_CONFIG_DIR=$temp_dir/config
WIREGUARD_SOURCE_CONFIG=$temp_dir/config/wireguard/wg0.conf
STATE_DIR=$temp_dir/state
DDNS_HOSTNAME=vpn.example.com
DDNS_POLL_SECONDS=60
DDNS_COOLDOWN_SECONDS=15
DDNS_RESOLVER=
DDNS_OVERRIDE_IP=203.0.113.10
HTTP_PROXY_PORT=8888
SOCKS5_PROXY_PORT=1080
SOCKS5_USER=
SOCKS5_PASSWORD=
VPROXY_IMAGE=ghcr.io/0x676e67/vproxy:latest
GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy
WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest
GLUETUN_IMAGE=qmcgaw/gluetun:latest
VPN_TYPE=openvpn
EOF

docker compose --env-file "$temp_dir/.env" -f "$repo_root/docker-compose.yml" config -q
printf 'Docker Compose validation passed.\n'
