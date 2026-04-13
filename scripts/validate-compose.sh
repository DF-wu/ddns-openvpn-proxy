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

cat >"$temp_dir/.env" <<EOF
TZ=UTC
OPENVPN_CONFIG_DIR=$repo_root/examples
OPENVPN_USER=
OPENVPN_PASSWORD=
SOCKS5_PORT=1080
SOCKS5_USER=socks5
SOCKS5_PASSWORD=change-me
LAN_NETWORK=192.168.1.0/24
NAME_SERVERS=1.1.1.1,1.0.0.1
PUID=0
PGID=0
UMASK=022
VPN_IMAGE=binhex/arch-privoxyvpn@sha256:75c98f92941ac0fd6d2c8533a51e3482472ed2651954836091e0e95148996469
EOF

docker compose --env-file "$temp_dir/.env" -f "$repo_root/docker-compose.yml" config -q
printf 'Docker Compose validation passed.\n'
